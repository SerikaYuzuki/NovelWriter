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
        guard (1 ... 500).contains(pageSize) else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }
        var state = try HistoryCursor.decode(cursor)

        if state.localItems.isEmpty, !state.localFinished {
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
            } catch SyncV2ApplicationError.workNotFound {
                state.localFinished = true
                state.localAvailable = false
            }
        }

        if state.remoteItems.isEmpty, !state.remoteFinished {
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

        let localAvailability: SyncV2HistoryAvailability = state.localAvailable
            ? .available : .unavailable
        let onlineAvailability: SyncV2HistoryAvailability = state.remoteAvailable
            ? .available : .unavailable
        var local = state.localItems
        var remote = state.remoteItems
        var result: [SyncV2HistoryItem] = []
        while result.count < pageSize, !local.isEmpty || !remote.isEmpty {
            let takeLocal: Bool = if local.isEmpty {
                false
            } else if remote.isEmpty {
                true
            } else {
                HistoryCursor.Entry.order(local[0], before: remote[0])
            }
            let entry = takeLocal ? local.removeFirst() : remote.removeFirst()
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
                    onlineAvailability: onlineAvailability
                )
            )
        }
        state.localItems = local
        state.remoteItems = remote
        let nextCursor: String? = state.hasMore ? state.encode() : nil
        return SyncV2HistoryPage(
            items: result,
            nextCursor: nextCursor,
            localAvailability: localAvailability,
            onlineAvailability: onlineAvailability,
            onlineFailure: state.remoteFailure
        )
    }
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

        init(_ item: SyncV2LocalHistoryOccurrence) {
            occurrenceID = item.occurrenceID
            snapshotID = item.snapshotID
            reason = item.reason
            pinned = item.pinned
            localGeneration = item.localGeneration
            createdAt = item.createdAt
            source = .local
        }

        init(_ item: SyncV2RemoteHistoryEntry) {
            occurrenceID = item.occurrenceID
            snapshotID = item.snapshotID
            reason = item.reason
            pinned = item.pinned
            localGeneration = nil
            createdAt = item.createdAt
            source = .remote
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

    static func decode(_ token: String?) throws -> HistoryCursor {
        guard let token else {
            return HistoryCursor(
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
              let cursor = try? JSONDecoder().decode(HistoryCursor.self, from: data) else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }
        return cursor
    }

    func encode() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
    }
}
