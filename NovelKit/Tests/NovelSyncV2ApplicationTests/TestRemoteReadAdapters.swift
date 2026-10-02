import NovelSyncV2
@testable import NovelSyncV2Application

extension InMemorySyncV2RuntimeState: SyncV2RemoteReads {
    public func catalogPage(cursor _: String?, pageSize _: Int) async throws -> SyncV2RemoteCatalogPage {
        throw SyncV2Failure.authenticationRequired
    }

    public func remoteHead(workID _: WorkID) async throws -> SyncV2RemoteHead? {
        throw SyncV2Failure.authenticationRequired
    }

    public func historyPage(workID _: WorkID, cursor _: String?, pageSize _: Int) async throws -> SyncV2RemoteHistoryPage {
        throw SyncV2Failure.authenticationRequired
    }

    public func remoteConflict(workID _: WorkID) async throws -> SyncV2ConflictProjection? {
        throw SyncV2Failure.authenticationRequired
    }
}
