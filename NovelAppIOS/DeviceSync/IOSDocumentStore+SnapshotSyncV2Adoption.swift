import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import NovelWorkspace

typealias AutoAdoptionExpectation = WorkspaceOperationContext

extension IOSDocumentStore {
    /// Adopt a verified remote resolution only after the iOS document gate,
    /// IME boundary, editor generation, and local pending intent are safe.
    @discardableResult
    func adoptPendingSnapshotSyncV2(
        expectedSession: WorkspaceSessionToken? = nil,
        expectedEditGeneration: UInt64? = nil,
        expectedAccountScope: WorkspaceAccountScope? = nil,
        automatically: Bool = false
    ) async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application,
              startupState == .ready,
              let activeWorkID = workspaceModel.activeWorkID,
              workspaceModel.libraryRows.first(where: { $0.workID == activeWorkID })?.accountState
              != .parkedDifferentAccount,
              let expectedSession = expectedSession ?? currentDocumentSessionToken else {
            return false
        }
        let expectedEditGeneration = expectedEditGeneration ?? workspaceModel.editGeneration
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        let operation = WorkspaceOperationContext(workID: expectedSession.workID, session: expectedSession,
                                                  account: expectedAccountScope, editGeneration: expectedEditGeneration)
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            guard matchesRemoteSyncAccount(expectedAccountScope) else { return false }
            guard currentDocumentSessionToken == expectedSession,
                  workspaceModel.editGeneration == expectedEditGeneration,
                  workspaceModel.saveState == .saved else {
                operationErrorMessage = "未保存の変更があります。端末へ適用する前に保存してください。"
                return false
            }
            // Do not commit an in-progress composition just because a remote
            // update arrived. The next foreground check can try again.
            guard automaticAdoptionExpectation(for: activeWorkID, validatingEditorSurface: true) != nil else { return false }
            isRemoteAdoptionInProgress = true
            defer { isRemoteAdoptionInProgress = false }
            var adopted = false
            let transitioned = await performDocumentTransition {
                do {
                    let port = WorkspaceAdoptionPort(
                        isCurrent: {
                            !self.isSyncV2RemoteAccountTransitionActive && self.matchesSyncOperation(operation)
                                && self.workspaceModel.saveState == .saved
                        }, session: { pending in await application.beginSession(workID: pending.workID) },
                        arm: { session, pending, projected in
                            #if !FUMINIWA_TEST_COMPOSITION
                            try await self.snapshotSyncV2DocumentGate.arm(
                                session: session, expectedLocalVersion: pending.expectedLocalVersion,
                                proof: SyncV2SafeBoundaryProof(
                                    editorGeneration: self.workspaceModel.editorContentGeneration,
                                    hasMarkedText: self.editorCommandSession.captureActiveCommittedText() == .compositionInProgress,
                                    hasUnsavedChanges: self.workspaceModel.saveState != .saved,
                                    pendingIntentCleared: projected.lastTypedResult == .adoptionPending
                                )
                            )
                            #endif
                        }, disarm: { await self.snapshotSyncV2DocumentGate.disarm(session: $0) },
                        claim: { !automatically || self.claimAutomaticAdoption($0, account: expectedAccountScope) },
                        install: { opened in
                            guard self.matchesSyncOperation(operation), let value = opened.document else { return false }
                            return self.installSnapshotSyncV2Opened(opened, value: value, preservingSelection: true)
                        }, project: { self.applySnapshotSyncV2State($0) }
                    )
                    adopted = try await AdoptionCoordinator(application: application).adoptAtPreparedBoundary(
                        host: self, workID: activeWorkID, port: port
                    )
                } catch {
                    guard !Task.isCancelled, matchesSyncOperation(operation) else { return }
                    snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
                    snapshotSyncV2RemoteOnlyOpenFailure = syncV2FailureKind(error)
                    logSyncV2PresentationFailure(error)
                    operationErrorMessage = remoteOnlyOpenErrorMessage(error)
                }
            }
            return transitioned && adopted
        }
    }

    func claimAutomaticAdoption(_ pending: SyncV2PendingAdoption, account: WorkspaceAccountScope) -> Bool {
        guard !pending.requiresExplicitConfirmation,
              workspaceModel.automaticAdoptionAttempts[account]?[pending.workID]?.contains(pending.inboxID) != true else { return false }
        workspaceModel.automaticAdoptionAttempts[account, default: [:]][pending.workID, default: []].insert(pending.inboxID)
        return true
    }

    func automaticAdoptionExpectation(
        for workID: WorkID,
        validatingEditorSurface: Bool
    ) -> AutoAdoptionExpectation? {
        guard !isSyncV2RemoteAccountTransitionActive,
              startupState == .ready,
              workspaceModel.activeWorkID == workID,
              let session = currentDocumentSessionToken,
              workspaceModel.saveState == .saved,
              !workspaceModel.isDocumentTransitionInProgress,
              workspaceModel.keepBothPendingWorkID == nil else { return nil }
        let editGeneration = workspaceModel.editGeneration
        let accountScope = snapshotSyncV2AccountScope

        if validatingEditorSurface {
            switch editorCommandSession.captureActiveCommittedText() {
            case let .captured(text):
                guard let episodeID = workspaceModel.selectedEpisodeID,
                      workspaceModel.document.episode(episodeID)?.episode.content == text else { return nil }
            case .compositionInProgress:
                return nil
            case .notActive:
                break
            }
        }

        guard workspaceModel.activeWorkID == workID,
              !isSyncV2RemoteAccountTransitionActive,
              currentDocumentSessionToken == session,
              workspaceModel.editGeneration == editGeneration,
              matchesSyncAccount(accountScope),
              workspaceModel.saveState == .saved else { return nil }
        return AutoAdoptionExpectation(workID: workID, session: session, account: accountScope, editGeneration: editGeneration)
    }

    func scheduleAutomaticAdoptionAfterCleanOpen(
        _ application: SyncV2Application,
        workID: WorkID
    ) {
        guard let projected = workspaceModel.syncUIState,
              projected.workID == workID,
              case .readyForSafeAdoption = projected.remoteProgress,
              let expectation = automaticAdoptionExpectation(
                  for: workID,
                  validatingEditorSurface: false
              ) else { return }
        startSnapshotSyncV2Reprojection(
            application,
            workID: workID,
            automaticAdoption: expectation,
            expectedAccountScope: expectation.account,
            resumesWorker: false
        )
    }
}
