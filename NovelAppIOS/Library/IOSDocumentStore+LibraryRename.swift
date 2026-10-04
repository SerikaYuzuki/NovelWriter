import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    func renameLibraryWork(
        _ item: SyncV2LibraryItem, title: String,
        expectedSession: WorkspaceSessionToken?,
        accountScope: WorkspaceAccountScope
    ) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        let context = WorkspaceOperationContext(workID: syncV2ActiveWorkID, session: expectedSession,
                                                account: accountScope, editGeneration: nil)
        var operations = LibraryOperations(application: application)
        operations.downloadForRename = { [self] in _ = try await openRemoteOnlyWithBackgroundTime(application, workID: $0) }
        do {
            return try await LibraryCoordinator(operations: operations).rename(
                workID: item.workID, remoteOnly: item.availability == .remoteOnly, title: title,
                context: context, host: self
            )
        } catch {
            guard LibraryCoordinator.matches(context, host: self) else { return false }
            operationErrorMessage = "作品名を変更できませんでした。接続を確認して再試行してください。"
            return false
        }
    }
}
