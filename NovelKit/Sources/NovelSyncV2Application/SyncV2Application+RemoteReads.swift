import NovelSyncV2

/// Explicit remote reads.  These calls refresh remote metadata only; they do
/// not open, adopt, or mutate a local work.  Remote-only content remains in
/// the verified Inbox path until the caller explicitly opens it.
public extension SyncV2Application {
    func refreshRemoteCatalog(
        cursor: String? = nil,
        pageSize: Int = 100
    ) async throws -> SyncV2RemoteCatalogPage {
        try await libraryProvider.catalogPage(cursor: cursor, pageSize: pageSize)
    }

    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        try await libraryProvider.remoteHead(workID: workID)
    }

    func remoteHistory(
        workID: WorkID,
        cursor: String? = nil,
        pageSize: Int = 100
    ) async throws -> SyncV2RemoteHistoryPage {
        try await libraryProvider.historyPage(workID: workID, cursor: cursor, pageSize: pageSize)
    }

    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        try await libraryProvider.remoteConflict(workID: workID)
    }
}
