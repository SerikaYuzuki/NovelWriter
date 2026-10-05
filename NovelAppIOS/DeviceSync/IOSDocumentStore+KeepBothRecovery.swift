import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    func clearKeepBothHandoff() {
        workspaceModel.keepBothPendingWorkID = nil
        workspaceModel.keepBothHandoff = nil
    }

    func retireFrozenKeepBothWorkForLibrary() {
        guard workspaceModel.keepBothPendingWorkID != nil else { return }
        cancelSnapshotSyncV2BackgroundOperations()
        startupState = .library
        workspaceModel.activeWorkID = nil
        clearKeepBothHandoff()
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        applySnapshotSyncV2State(nil)
        operationErrorMessage = nil
        workspaceModel.saveState = .saved
        userDefaults.removeObject(forKey: Self.lastWorkIDKey)
    }

    func installKeepBothOpenedWork(_ opened: SyncV2OpenedWork, context: WorkspaceOperationContext) async -> Bool {
        #if FUMINIWA_TEST_COMPOSITION
        if let snapshotSyncV2KeepBothInstallOverride {
            guard await snapshotSyncV2KeepBothInstallOverride() else { return false }
        }
        #endif
        guard context.isCurrent(operationContext), workspaceModel.keepBothPendingWorkID == opened.workID,
              let value = opened.document else { return false }
        return installSnapshotSyncV2Opened(opened, value: value)
    }

    @discardableResult
    func retryKeepBothHandoff() async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive, !workspaceModel.isDocumentTransitionInProgress,
              startupState == .ready, let application = snapshotSyncV2Application,
              let handoff = workspaceModel.keepBothHandoff,
              workspaceModel.keepBothPendingWorkID == handoff.action.newWorkID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2RemoteAccountTransitionActive, !workspaceModel.isDocumentTransitionInProgress,
                  handoff.context.isCurrent(operationContext),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            workspaceModel.isDocumentTransitionInProgress = true
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                workspaceModel.isDocumentTransitionInProgress = false
            }
            do {
                let installed = try await ConflictCoordinator(application: application).retryKeepBothAtPreparedBoundary(
                    host: self, handoff: handoff,
                    isCurrent: { !self.isSyncV2RemoteAccountTransitionActive
                        && self.snapshotSyncV2Application === application
                        && self.workspaceModel.keepBothPendingWorkID == handoff.action.newWorkID
                    }, install: { opened, _ in await self.installKeepBothOpenedWork(opened, context: handoff.context) },
                    project: { self.applySnapshotSyncV2State($0) },
                    resume: {
                        self.startSnapshotSyncV2Reprojection(
                            application, workID: self.workspaceModel.activeWorkID, automaticAdoption: nil,
                            expectedAccountScope: handoff.context.account, resumesWorker: true
                        )
                    }
                )
                if installed {
                    operationErrorMessage = nil
                }
                return installed
            } catch {
                return false
            }
        }
    }
}
