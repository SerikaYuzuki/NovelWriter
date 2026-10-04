import NovelWorkspace

extension AppState {
    func deleteLibraryWork(_ work: StartupLibraryWork, accountScope: WorkspaceAccountScope) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        let context = WorkspaceOperationContext(workID: currentSnapshotSyncV2WorkID, session: documentSessionToken,
                                                account: accountScope, editGeneration: nil)
        do {
            return try await LibraryCoordinator(operations: LibraryOperations(application: application)).delete(
                workID: work.workID, context: context, host: self
            )
        } catch {
            guard matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
            operationMessage = "削除はまだ完了していません。端末のデータを保持して削除待ちにしました。接続時に再試行します。右クリックの「削除…」からも再試行できます。"
            await refreshSnapshotLibrary()
            return false
        }
    }
}
