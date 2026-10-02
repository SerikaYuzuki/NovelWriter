import NovelSyncV2

public extension FakeSyncV2RemoteClient {
    func setHistoryEntries(_ entries: [SyncV2RemoteHistoryEntry], workID: WorkID) {
        historyEntries[workID] = entries
    }

    func historyPage(workID: WorkID, cursor _: String?, pageSize: Int) async throws -> SyncV2RemoteHistoryPage {
        guard let entries = historyEntries[workID] else { throw SyncV2Failure.offline }
        return SyncV2RemoteHistoryPage(items: Array(entries.prefix(pageSize)), nextCursor: nil)
    }

    func setHistoryBackfillHandler(_ handler: (@Sendable (WorkID, Bool, @escaping @Sendable () async -> Void) async throws -> Void)?) {
        historyBackfillHandler = handler
    }

    func backfillHistory(workID: WorkID, manual: Bool, allowConstrained _: Bool = false, progress: @escaping @Sendable () async -> Void) async throws {
        try await historyBackfillHandler?(workID, manual, progress)
    }
}
