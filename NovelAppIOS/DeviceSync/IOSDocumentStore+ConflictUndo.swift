import NovelSyncV2
import NovelSyncV2Application

extension IOSDocumentStore {
    func undoConflictSelection(_ selection: IOSSnapshotSyncV2ConflictSelection,
                               choice: SyncV2ConflictChoice, snapshotID: SnapshotID) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        return await SnapshotConflictUndo.restore(
            application: application, workID: selection.workID, snapshotID: snapshotID,
            serverChoice: choice == .useServer,
            isCurrent: { self.syncV2ActiveWorkID == selection.workID && self.snapshotSyncV2AccountScope == selection.accountScope },
            adopt: { await self.adoptPendingSnapshotSyncV2() },
            restore: { await self.restoreSnapshotSyncV2(snapshotID: $0.rawValue) }
        )
    }
}
