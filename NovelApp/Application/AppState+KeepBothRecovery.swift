import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension AppState {
    func clearKeepBothHandoff() {
        workspaceModel.keepBothPendingWorkID = nil
        workspaceModel.keepBothHandoff = nil
        syncV2KeepBothSourceSelection = nil
    }

    /// The source remains in SQLite; retiring its editor makes library return
    /// safe without checkpointing it or leaving a writable frozen session.
    func retireFrozenKeepBothWorkForLibrary() {
        guard workspaceModel.keepBothPendingWorkID != nil else { return }
        cancelSnapshotSyncV2BackgroundOperations()
        clearKeepBothHandoff()
        workspaceModel.activeWorkID = nil
        snapshotSyncV2Session = nil
        workspaceModel.editorContentGeneration &+= 1
        workspaceModel.documentSessionToken = WorkspaceSessionToken(
            generation: workspaceModel.editorContentGeneration, documentID: workspaceModel.document.id, workID: WorkID(UUID())
        )
        applySnapshotSyncV2State(nil)
        operationMessage = nil
        workspaceModel.saveState = .saved
        userDefaults.removeObject(forKey: "fuminiwa.v2.activeWorkID")
        userDefaults.set(true, forKey: "fuminiwa.v2.startInLibrary")
    }

    @discardableResult
    func retryKeepBothHandoff() async -> Bool {
        guard permitsDocumentDeparture, let application = snapshotSyncV2Application,
              let handoff = workspaceModel.keepBothHandoff, let selection = syncV2KeepBothSourceSelection,
              workspaceModel.keepBothPendingWorkID == handoff.action.newWorkID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self, permitsDocumentDeparture, handoff.context.isCurrent(operationContext),
                  snapshotSyncV2Session == selection.snapshotSession,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            workspaceModel.isDocumentTransitionInProgress = true
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                workspaceModel.isDocumentTransitionInProgress = false
            }
            do {
                let installed = try await ConflictCoordinator(application: application).retryKeepBothAtPreparedBoundary(
                    host: self, handoff: handoff,
                    isCurrent: { self.snapshotSyncV2Application === application
                        && self.snapshotSyncV2Session == selection.snapshotSession
                        && self.workspaceModel.keepBothPendingWorkID == handoff.action.newWorkID
                    }, install: { opened, action in
                        await self.installKeepBothOpenedWork(
                            opened, using: application, sourceSelection: selection,
                            expectedWorkID: action.newWorkID, expectedDocumentID: action.newDocumentID
                        )
                    }, project: { self.applySnapshotSyncV2State($0) },
                    resume: { self.resumeKeepBothTransport(application) }
                )
                if installed {
                    operationMessage = nil
                }
                return installed
            } catch {
                return false
            }
        }
    }

    func resumeKeepBothTransport(_ application: SyncV2Application) {
        let context = CheckpointCoordinator.context(of: self)
        Task { @MainActor [weak self] in
            guard let self, CheckpointCoordinator.matches(context, host: self),
                  snapshotSyncV2Application === application else { return }
            try? await application.resumePending()
            guard CheckpointCoordinator.matches(context, host: self) else { return }
            await refreshSnapshotSyncV2UIState()
            await refreshSnapshotLibrary()
        }
    }
}
