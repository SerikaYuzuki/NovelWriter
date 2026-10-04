import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    func clearKeepBothHandoff() {
        syncV2KeepBothPendingWorkID = nil
        syncV2KeepBothHandoff = nil
    }

    func retireFrozenKeepBothWorkForLibrary() {
        guard syncV2KeepBothPendingWorkID != nil else { return }
        cancelSnapshotSyncV2BackgroundOperations()
        startupState = .library
        syncV2ActiveWorkID = nil
        clearKeepBothHandoff()
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        applySnapshotSyncV2State(nil)
        operationErrorMessage = nil
        saveState = .saved
        userDefaults.removeObject(forKey: Self.lastWorkIDKey)
    }

    func installKeepBothOpenedWork(_ opened: SyncV2OpenedWork, context: WorkspaceOperationContext) async -> Bool {
        #if FUMINIWA_TEST_COMPOSITION
        if let snapshotSyncV2KeepBothInstallOverride {
            guard await snapshotSyncV2KeepBothInstallOverride() else { return false }
        }
        #endif
        guard context.isCurrent(operationContext), syncV2KeepBothPendingWorkID == opened.workID,
              let value = opened.document else { return false }
        return installSnapshotSyncV2Opened(opened, value: value)
    }

    @discardableResult
    func retryKeepBothHandoff() async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive, !isDocumentTransitionInProgress,
              startupState == .ready, let application = snapshotSyncV2Application,
              let handoff = syncV2KeepBothHandoff,
              syncV2KeepBothPendingWorkID == handoff.action.newWorkID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2RemoteAccountTransitionActive, !isDocumentTransitionInProgress,
                  handoff.context.isCurrent(operationContext),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            isDocumentTransitionInProgress = true
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                isDocumentTransitionInProgress = false
            }
            do {
                let installed = try await ConflictCoordinator(application: application).retryKeepBothAtPreparedBoundary(
                    host: self, handoff: handoff,
                    isCurrent: { !self.isSyncV2RemoteAccountTransitionActive
                        && self.snapshotSyncV2Application === application
                        && self.syncV2KeepBothPendingWorkID == handoff.action.newWorkID
                    }, install: { opened, _ in await self.installKeepBothOpenedWork(opened, context: handoff.context) },
                    project: { self.applySnapshotSyncV2State($0) },
                    resume: {
                        self.startSnapshotSyncV2Reprojection(
                            application, workID: self.syncV2ActiveWorkID, automaticAdoption: nil,
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
