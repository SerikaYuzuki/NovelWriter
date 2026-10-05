import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    func libraryDeletionDisabledReason(for workID: WorkID) -> String? {
        if libraryPrefetchWorkID == workID || snapshotSyncV2RemoteOnlyOpeningWorkID == workID {
            return "作品を取り込み中のため削除できません。取り込みを中止するか、完了後に再試行してください。"
        }
        if workspaceModel.isDocumentTransitionInProgress || isSyncV2RemoteAccountTransitionActive {
            return "作品やアカウントを切り替え中です。完了後に再試行してください。"
        }
        return nil
    }

    func deleteLibraryWork(
        _ item: SyncV2LibraryItem, expectedSession: WorkspaceSessionToken?,
        accountScope: WorkspaceAccountScope
    ) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        let context = WorkspaceOperationContext(workID: workspaceModel.activeWorkID, session: expectedSession,
                                                account: accountScope, editGeneration: nil)
        do {
            return try await LibraryCoordinator(operations: LibraryOperations(application: application)).delete(
                workID: item.workID, context: context, host: self
            )
        } catch {
            guard matchesSyncAccount(accountScope) else { return false }
            operationErrorMessage = "削除はまだ完了していません。端末のデータを保持して削除待ちにしました。接続時に再試行します。「作品を削除…」からも再試行できます。"
            _ = await refreshLibrary()
            return false
        }
    }
}
