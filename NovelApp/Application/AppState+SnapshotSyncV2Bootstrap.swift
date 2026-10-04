import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension AppState {
    /// Launch preferences and fresh-work recovery remain in bootstrap. This
    /// adapter only prepares the editor boundary for the shared local open.
    func openBootstrapSnapshotWork(_ workID: WorkID, application: SyncV2Application) async throws -> Bool {
        let expected = operationContext
        let coordinator = workspaceWorkOpenCoordinator(application)
        guard let opened = try await coordinator.readLocal(workID: workID, isCurrent: {
            expected.isCurrent(self.operationContext)
        }) else { return false }
        let installed = await documentOperationGate.perform { [weak self] in
            guard let self, expected.isCurrent(operationContext),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            if saveState != .saved, currentSnapshotSyncV2WorkID != nil {
                guard await saveNow() else { return false }
            }
            return await (try? coordinator.installAtPreparedBoundary(
                opened, workID: workID, host: self, createsSession: true,
                install: { opened, session in
                    guard let value = opened.document,
                          self.installV2Document(value, workID: opened.workID, createdAt: opened.documentCreatedAt,
                                                 attachments: opened.attachments, resources: opened.resources,
                                                 expectedWorkID: workID) else { return false }
                    self.snapshotSyncV2Session = session
                    return true
                }, project: { self.applySnapshotSyncV2State($0) }
            )) == true
        }
        guard installed else {
            if expected.isCurrent(operationContext) {
                startupState = .recovery(.init(message: "保存済みの作品を検証できませんでした。"))
            }
            return false
        }
        return true
    }
}
