import Foundation
import NovelSyncV2

public extension SyncV2Application {
    /// Lists local and online occurrences through one stable view. Sources are
    /// merged by newest `createdAt`; equal timestamps use occurrence ID and
    /// then source as a deterministic tie-breaker. A SnapshotID is never used
    /// as a deduplication key.
    func historyPage(
        workID: WorkID,
        cursor: String? = nil,
        pageSize: Int = 100
    ) async throws -> SyncV2HistoryPage {
        try await readHistoryPage(workID: workID, cursor: cursor, pageSize: pageSize, locallyAvailableSnapshots: [])
    }
}

enum HistoryReadPhase: Sendable { case local, online }

extension SyncV2Application {
    /// Episode metadata already proves these bodies readable. Keep the same
    /// occurrence merge/cursor, avoiding a second SQL/actor round trip per row.
    func readHistoryPage(workID: WorkID, cursor: String?, pageSize: Int,
                         locallyAvailableSnapshots: Set<SnapshotID>,
                         timing: (@Sendable (HistoryReadPhase, Duration) -> Void)? = nil,
                         initialLocalPage: SyncV2LocalHistoryPage? = nil) async throws -> SyncV2HistoryPage {
        guard (1 ... 500).contains(pageSize) else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }
        let requestScopeGeneration = historyScopeGeneration
        var state = try HistoryCursor.decode(
            cursor,
            expectedScopeGeneration: requestScopeGeneration
        )

        if cursor == nil, let initialLocalPage {
            state.localAvailable = true
            state.localItems = initialLocalPage.items.map { HistoryCursor.Entry($0) }
            state.localCursor = initialLocalPage.nextCursor
            state.localFinished = initialLocalPage.nextCursor == nil
        }
        try Task.checkCancellation()
        if state.localItems.isEmpty, !state.localFinished {
            let start = ContinuousClock.now
            defer { timing?(.local, start.duration(to: .now)) }
            do {
                let page = try await kernel.localHistoryPage(
                    workID: workID,
                    cursor: state.localCursor,
                    pageSize: pageSize
                )
                state.localAvailable = true
                state.localItems = page.items.map { HistoryCursor.Entry($0) }
                state.localCursor = page.nextCursor
                state.localFinished = page.nextCursor == nil
                guard historyScopeGeneration == requestScopeGeneration else {
                    throw SyncV2ApplicationError.invalidHistoryCursor
                }
            } catch SyncV2ApplicationError.workNotFound {
                state.localFinished = true
                state.localAvailable = false
            }
        }

        try Task.checkCancellation()
        if state.remoteItems.isEmpty, !state.remoteFinished {
            let start = ContinuousClock.now
            defer { timing?(.online, start.duration(to: .now)) }
            do {
                let page = try await remote.historyPage(
                    workID: workID,
                    cursor: state.remoteCursor,
                    pageSize: pageSize
                )
                state.remoteAvailable = true
                state.remoteFailure = nil
                state.remoteItems = page.items.map { HistoryCursor.Entry($0) }
                state.remoteCursor = page.nextCursor
                state.remoteFinished = page.nextCursor == nil
                guard historyScopeGeneration == requestScopeGeneration else {
                    throw SyncV2ApplicationError.invalidHistoryCursor
                }
            } catch let error as SyncV2ApplicationError {
                throw error
            } catch let failure as SyncV2Failure {
                state.remoteFinished = true
                state.remoteAvailable = false
                state.remoteFailure = failure
            } catch {
                state.remoteFinished = true
                state.remoteAvailable = false
                state.remoteFailure = .offline
            }
        }

        guard state.localAvailable || state.remoteAvailable else {
            if let failure = state.remoteFailure {
                throw failure
            }
            throw SyncV2ApplicationError.workNotFound
        }
        guard historyScopeGeneration == requestScopeGeneration else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }

        try Task.checkCancellation()
        let page = projectHistoryPage(state: &state, pageSize: pageSize)
        var items: [SyncV2HistoryItem] = []
        for var item in page.items {
            item.snapshotAvailability = if locallyAvailableSnapshots.contains(item.snapshotID) {
                .local
            } else {
                await (try? kernel.snapshotAvailability(workID: workID, snapshotID: item.snapshotID)) ?? .unknown
            }
            items.append(item)
        }
        guard historyScopeGeneration == requestScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        return SyncV2HistoryPage(items: items, nextCursor: page.nextCursor, localAvailability: page.localAvailability,
                                 onlineAvailability: page.onlineAvailability, onlineFailure: page.onlineFailure)
    }
}

private func projectHistoryPage(
    state: inout HistoryCursor,
    pageSize: Int
) -> SyncV2HistoryPage {
    let localAvailability: SyncV2HistoryAvailability = state.localAvailable
        ? .available : .unavailable
    let onlineAvailability: SyncV2HistoryAvailability = state.remoteAvailable
        ? .available : .unavailable
    let local = state.localItems
    let remote = state.remoteItems
    var localIndex = 0
    var remoteIndex = 0
    var result: [SyncV2HistoryItem] = []
    while result.count < pageSize, localIndex < local.count || remoteIndex < remote.count {
        // Refill an exhausted source before consuming the other source: its
        // next page may contain newer rows. Array offsets avoid removeFirst O(n²).
        if localIndex == local.count, !state.localFinished {
            break
        }
        if remoteIndex == remote.count, !state.remoteFinished {
            break
        }
        let takeLocal: Bool = if localIndex == local.count {
            false
        } else if remoteIndex == remote.count {
            true
        } else {
            HistoryCursor.Entry.order(local[localIndex], before: remote[remoteIndex])
        }
        let entry = takeLocal ? local[localIndex] : remote[remoteIndex]
        if takeLocal {
            localIndex += 1
        } else {
            remoteIndex += 1
        }
        result.append(
            SyncV2HistoryItem(
                occurrenceID: entry.occurrenceID,
                snapshotID: entry.snapshotID,
                reason: entry.reason,
                pinned: entry.pinned,
                localGeneration: entry.localGeneration,
                createdAt: entry.createdAt,
                source: entry.source,
                localAvailability: localAvailability,
                onlineAvailability: onlineAvailability,
                deviceLabel: entry.deviceLabel
            )
        )
    }
    state.localItems = Array(local.dropFirst(localIndex))
    state.remoteItems = Array(remote.dropFirst(remoteIndex))
    let nextCursor: String? = state.hasMore ? state.encode() : nil
    return SyncV2HistoryPage(
        items: result,
        nextCursor: nextCursor,
        localAvailability: localAvailability,
        onlineAvailability: onlineAvailability,
        onlineFailure: state.remoteFailure
    )
}

private struct HistoryCursor: Codable {
    struct Entry: Codable, Hashable {
        let occurrenceID: UUID
        let snapshotID: SnapshotID
        let reason: String
        let pinned: Bool
        let localGeneration: Int64?
        let createdAt: Date
        let source: SyncV2HistorySource
        let deviceLabel: String?

        init(_ item: SyncV2LocalHistoryOccurrence) {
            occurrenceID = item.occurrenceID
            snapshotID = item.snapshotID
            reason = item.reason
            pinned = item.pinned
            localGeneration = item.localGeneration
            createdAt = item.createdAt
            source = .local
            deviceLabel = nil
        }

        init(_ item: SyncV2RemoteHistoryEntry) {
            occurrenceID = item.occurrenceID
            snapshotID = item.snapshotID
            reason = item.reason
            pinned = item.pinned
            localGeneration = nil
            createdAt = item.createdAt
            source = .remote
            deviceLabel = item.deviceLabel
        }

        static func order(_ lhs: Entry, before rhs: Entry) -> Bool {
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            let leftID = lhs.occurrenceID.uuidString.lowercased()
            let rightID = rhs.occurrenceID.uuidString.lowercased()
            if leftID != rightID {
                return leftID > rightID
            }
            return lhs.source == .local && rhs.source == .remote
        }
    }

    let scopeGeneration: UInt64
    var localCursor: String?
    var remoteCursor: String?
    var localItems: [Entry]
    var remoteItems: [Entry]
    var localFinished: Bool
    var remoteFinished: Bool
    var localAvailable: Bool
    var remoteAvailable: Bool
    var remoteFailure: SyncV2Failure? = nil

    enum CodingKeys: String, CodingKey {
        case scopeGeneration
        case localCursor
        case remoteCursor
        case localItems
        case remoteItems
        case localFinished
        case remoteFinished
        case localAvailable
        case remoteAvailable
    }

    var hasMore: Bool {
        !localItems.isEmpty || !remoteItems.isEmpty || !localFinished || !remoteFinished
    }

    static func decode(
        _ token: String?,
        expectedScopeGeneration: UInt64
    ) throws -> HistoryCursor {
        guard let token else {
            return HistoryCursor(
                scopeGeneration: expectedScopeGeneration,
                localCursor: nil,
                remoteCursor: nil,
                localItems: [],
                remoteItems: [],
                localFinished: false,
                remoteFinished: false,
                localAvailable: false,
                remoteAvailable: false,
                remoteFailure: nil
            )
        }
        guard let data = Data(base64Encoded: token),
              let cursor = try? JSONDecoder().decode(HistoryCursor.self, from: data),
              cursor.scopeGeneration == expectedScopeGeneration else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }
        return cursor
    }

    func encode() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
    }
}
