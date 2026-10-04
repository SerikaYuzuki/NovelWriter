import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    func undoConflictSelection(_ selection: IOSSnapshotSyncV2ConflictSelection,
                               choice: SyncV2ConflictChoice, snapshotID: SnapshotID) async -> Bool {
        guard let application = snapshotSyncV2Application,
              syncV2ActiveWorkID == selection.workID,
              snapshotSyncV2AccountScope == selection.accountScope else { return false }
        var context = CheckpointCoordinator.context(of: self)
        return await ConflictCoordinator(application: application).undo(
            workID: selection.workID, snapshotID: snapshotID,
            serverChoice: choice == .useServer,
            isCurrent: { CheckpointCoordinator.matches(context, host: self) },
            adopt: {
                guard await self.adoptPendingSnapshotSyncV2(),
                      self.syncV2ActiveWorkID == selection.workID,
                      self.snapshotSyncV2AccountScope == selection.accountScope else { return false }
                context = CheckpointCoordinator.context(of: self)
                return true
            },
            restore: { await self.restoreSnapshotSyncV2(snapshotID: $0.rawValue) }
        )
    }
}
