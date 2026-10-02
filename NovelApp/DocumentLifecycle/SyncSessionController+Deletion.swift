import NovelSyncV2
import NovelSyncV2Application

extension SyncSessionController {
    /// Both hosts call this inside their document gate and exclusive save lane,
    /// after committing IME and flushing. No HTTP is performed in this boundary.
    func prepareWorkDeletion(
        application: SyncV2Application, workID: WorkID,
        isCurrent: () -> Bool, retireEditor: () -> Void
    ) async throws {
        guard isCurrent() else { throw SyncV2ApplicationError.safeBoundaryRejected }
        _ = try await application.prepareWorkDeletion(workID: workID)
        guard isCurrent() else { throw SyncV2ApplicationError.safeBoundaryRejected }
        retireEditor()
    }
}
