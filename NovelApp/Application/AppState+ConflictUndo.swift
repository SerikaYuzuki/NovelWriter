import NovelSyncV2
import NovelSyncV2Application

extension AppState {
    /// A queued server choice has not installed its content yet. Wait outside
    /// the document gate, then use the same safe adoption and restore paths.
    func undoConflictSelection(_ selection: SnapshotSyncV2ConflictSelection,
                               choice: SyncV2ConflictChoice, snapshotID: SnapshotID) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        return await SnapshotConflictUndo.restore(
            application: application, workID: selection.workID, snapshotID: snapshotID,
            serverChoice: choice == .useServer,
            isCurrent: { self.currentSnapshotSyncV2WorkID == selection.workID && self.matchesSnapshotSyncV2AccountScope(selection.accountScope) },
            adopt: { await self.applySnapshotSyncV2ServerVersion() },
            restore: { await self.restoreSnapshotV2(snapshotID: $0) }
        )
    }
}
