import Foundation
import NovelSyncV2

/// An in-process continuation, tied to the work and account generation. The
/// first page is local-only so a slow/offline server never delays visible rows.
public struct HistoryLoadingCursor: Sendable {
    let workID: WorkID
    let scopeGeneration: UInt64
    let initialLocalPage: SyncV2LocalHistoryPage?
    let mergedCursor: String?
    let onlineFailure: SyncV2Failure?
}

public struct HistoryLoadingPage: Sendable {
    public let items: [SyncV2HistoryItem]
    public let next: HistoryLoadingCursor?
    /// Online rows can precede local rows. Replace the provisional local first
    /// page with the first sorted merge, then append each older merged page.
    public let replacesItems: Bool
    public let onlineFailure: SyncV2Failure?
}

public extension SyncV2Application {
    func firstHistoryPage(workID: WorkID, pageSize: Int = 100) async throws -> HistoryLoadingPage {
        try await firstHistoryPage(workID: workID, pageSize: pageSize, locallyAvailableSnapshots: [])
    }

    func olderHistoryPage(_ cursor: HistoryLoadingCursor, pageSize: Int = 500) async throws -> HistoryLoadingPage {
        try await olderHistoryPage(cursor, pageSize: pageSize, locallyAvailableSnapshots: [])
    }
}

extension SyncV2Application {
    func firstHistoryPage(workID: WorkID, pageSize: Int,
                          locallyAvailableSnapshots: Set<SnapshotID>) async throws -> HistoryLoadingPage {
        guard (1 ... 500).contains(pageSize) else { throw SyncV2ApplicationError.invalidHistoryCursor }
        let scope = historyScopeGeneration
        try Task.checkCancellation()
        let local: SyncV2LocalHistoryPage
        do {
            local = try await kernel.localHistoryPage(workID: workID, cursor: nil, pageSize: pageSize)
        } catch SyncV2ApplicationError.workNotFound {
            // Whole-work history also serves remote-only works.
            local = .init(items: [], nextCursor: nil)
        }
        var items: [SyncV2HistoryItem] = []
        for entry in local.items {
            let availability: SyncV2SnapshotAvailability = if locallyAvailableSnapshots.contains(entry.snapshotID) {
                .local
            } else {
                await (try? kernel.snapshotAvailability(workID: workID, snapshotID: entry.snapshotID)) ?? .unknown
            }
            var item = SyncV2HistoryItem(occurrenceID: entry.occurrenceID, snapshotID: entry.snapshotID,
                                         reason: entry.reason, pinned: entry.pinned, localGeneration: entry.localGeneration,
                                         createdAt: entry.createdAt, source: .local, localAvailability: .available,
                                         onlineAvailability: .unavailable)
            item.snapshotAvailability = availability
            items.append(item)
        }
        try Task.checkCancellation()
        guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        return HistoryLoadingPage(items: items,
                                  next: .init(workID: workID, scopeGeneration: scope, initialLocalPage: local,
                                              mergedCursor: nil, onlineFailure: nil),
                                  replacesItems: true, onlineFailure: nil)
    }

    func olderHistoryPage(_ cursor: HistoryLoadingCursor, pageSize: Int,
                          locallyAvailableSnapshots: Set<SnapshotID>) async throws -> HistoryLoadingPage {
        try Task.checkCancellation()
        guard cursor.scopeGeneration == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        let page = try await readHistoryPage(workID: cursor.workID, cursor: cursor.mergedCursor,
                                             pageSize: pageSize, locallyAvailableSnapshots: locallyAvailableSnapshots,
                                             initialLocalPage: cursor.initialLocalPage)
        try Task.checkCancellation()
        guard cursor.scopeGeneration == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        let failure = page.onlineFailure ?? cursor.onlineFailure
        let next = page.nextCursor.map {
            HistoryLoadingCursor(workID: cursor.workID, scopeGeneration: cursor.scopeGeneration,
                                 initialLocalPage: nil, mergedCursor: $0, onlineFailure: failure)
        }
        return HistoryLoadingPage(items: page.items, next: next,
                                  replacesItems: cursor.initialLocalPage != nil, onlineFailure: failure)
    }
}
