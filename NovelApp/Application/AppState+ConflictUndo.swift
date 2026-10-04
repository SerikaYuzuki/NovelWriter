import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension AppState {
    /// A queued server choice has not installed its content yet. Wait outside
    /// the document gate, then use the same safe adoption and restore paths.
    func undoConflictSelection(_ selection: SnapshotSyncV2ConflictSelection,
                               choice: SyncV2ConflictChoice, snapshotID: SnapshotID) async -> Bool {
        guard let application = snapshotSyncV2Application,
              currentSnapshotSyncV2WorkID == selection.workID,
              matchesSnapshotSyncV2AccountScope(selection.accountScope) else { return false }
        var context = CheckpointCoordinator.context(of: self)
        var snapshotSession = snapshotSyncV2Session
        return await ConflictCoordinator(application: application).undo(
            workID: selection.workID, snapshotID: snapshotID, serverChoice: choice == .useServer,
            isCurrent: {
                CheckpointCoordinator.matches(context, host: self) && self.snapshotSyncV2Session == snapshotSession
            }, adopt: {
                guard await self.applySnapshotSyncV2ServerVersion(),
                      self.currentSnapshotSyncV2WorkID == selection.workID,
                      self.matchesSnapshotSyncV2AccountScope(selection.accountScope) else { return false }
                context = CheckpointCoordinator.context(of: self)
                snapshotSession = self.snapshotSyncV2Session
                return true
            }, restore: { await self.restoreSnapshotV2(snapshotID: $0) }
        )
    }
}
