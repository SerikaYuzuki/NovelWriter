import NovelWorkspace

extension AppState {
    func renameLibraryWork(
        _ work: StartupLibraryWork, title: String,
        expectedSession: WorkspaceSessionToken,
        accountScope: WorkspaceAccountScope
    ) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        let context = WorkspaceOperationContext(workID: currentSnapshotSyncV2WorkID, session: expectedSession,
                                                account: accountScope, editGeneration: nil)
        do {
            return try await LibraryCoordinator(operations: LibraryOperations(application: application)).rename(
                workID: work.workID, remoteOnly: work.availability == .remoteOnly, title: title,
                context: context, host: self
            )
        } catch {
            guard LibraryCoordinator.matches(context, host: self) else { return false }
            operationMessage = "作品を取得できませんでした。接続を確認して再試行してください。"
            return false
        }
    }
}
