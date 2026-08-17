import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

struct AutoAdoptionExpectation: Sendable {
    let session: IOSDocumentSessionToken
    let editGeneration: UInt64
    let accountScope: IOSSnapshotSyncV2AccountScope
}

extension IOSDocumentStore {
    /// Adopt a verified remote resolution only after the iOS document gate,
    /// IME boundary, editor generation, and local pending intent are safe.
    @discardableResult
    func adoptPendingSnapshotSyncV2(
        expectedSession: IOSDocumentSessionToken? = nil,
        expectedEditGeneration: UInt64? = nil,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope? = nil
    ) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application,
              startupState == .ready,
              let activeWorkID = syncV2ActiveWorkID,
              syncV2LibraryItems.first(where: { $0.workID == activeWorkID })?.accountState
              != .parkedDifferentAccount,
              let expectedSession = expectedSession ?? currentDocumentSessionToken else {
            return false
        }
        let expectedEditGeneration = expectedEditGeneration ?? localEditGeneration
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            guard !isSyncV2AccountTransitionActive,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            guard currentDocumentSessionToken == expectedSession,
                  localEditGeneration == expectedEditGeneration,
                  saveState == .saved else {
                operationErrorMessage = "未保存の変更があります。端末へ適用する前に保存してください。"
                return false
            }
            var adopted = false
            let transitioned = await performDocumentTransition {
                do {
                    // `prepareForDocumentTransition` can commit marked text
                    // and advance the edit generation.  Revalidate after that
                    // commit/save boundary so a just-finished IME composition
                    // is never replaced by the staged remote snapshot.
                    guard syncV2ActiveWorkID == activeWorkID,
                          !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          saveState == .saved else { return }
                    // The worker already projected the receipt into the durable
                    // application state. Reading uiState/pendingAdoption is
                    // local; adoption never performs a second network round trip.
                    guard let projected = await application.uiState(workID: activeWorkID),
                          projected.lastTypedResult == .adoptionPending,
                          case let .readyForSafeAdoption(inboxID) = projected.remoteProgress,
                          !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    guard let pending = try await application.pendingAdoption(workID: activeWorkID),
                          pending.workID == activeWorkID,
                          pending.inboxID == inboxID,
                          !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    applySnapshotSyncV2State(projected)

                    let session = await application.beginSession(workID: pending.workID)
                    guard !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    #if !FUMINIWA_TEST_COMPOSITION
                    // ProductionRuntimeConfiguration receives this exact
                    // platform gate. The compile-time test runtime owns an
                    // isolated in-memory gate instead; the iOS checks above
                    // prove its IME/save/session boundary before asking that
                    // application-owned gate for a one-shot token.
                    try await snapshotSyncV2DocumentGate.arm(
                        session: session,
                        expectedLocalVersion: pending.expectedLocalVersion,
                        proof: SyncV2SafeBoundaryProof(
                            editorGeneration: editorContentGeneration,
                            hasMarkedText: false,
                            hasUnsavedChanges: saveState != .saved,
                            pendingIntentCleared: projected.lastTypedResult == .adoptionPending
                        )
                    )
                    #endif
                    let token = try await application.documentGateToken(for: session)
                    guard !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    let boundary = SafeAdoptionBoundary(
                        workID: pending.workID,
                        inboxID: pending.inboxID,
                        session: session,
                        gate: token
                    )
                    let opened = try await application.applyStagedRemote(at: boundary)
                    guard !isSyncV2AccountTransitionActive,
                          opened.workID == activeWorkID,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    guard let value = opened.document else { return }
                    guard !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          installSnapshotSyncV2Opened(opened, value: value) else { return }
                    let adoptedState = await application.uiState(workID: opened.workID)
                    guard !isSyncV2AccountTransitionActive,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    applySnapshotSyncV2State(adoptedState)
                    adopted = true
                } catch {
                    guard snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    snapshotSyncOutcome = .failed
                }
            }
            return transitioned && adopted
        }
    }

    func automaticAdoptionExpectation(
        for workID: WorkID,
        validatingEditorSurface: Bool
    ) -> AutoAdoptionExpectation? {
        guard !isSyncV2AccountTransitionActive,
              startupState == .ready,
              syncV2ActiveWorkID == workID,
              let session = currentDocumentSessionToken,
              saveState == .saved,
              !isDocumentTransitionInProgress,
              syncV2KeepBothPendingWorkID == nil else { return nil }
        let editGeneration = localEditGeneration
        let accountScope = snapshotSyncV2AccountScope

        if validatingEditorSurface {
            switch editorCommandSession.captureActiveCommittedText() {
            case let .captured(text):
                guard let episodeID = selectedEpisodeID,
                      document.episode(episodeID)?.episode.content == text else { return nil }
            case .compositionInProgress:
                return nil
            case .notActive:
                break
            }
        }

        guard syncV2ActiveWorkID == workID,
              !isSyncV2AccountTransitionActive,
              currentDocumentSessionToken == session,
              localEditGeneration == editGeneration,
              snapshotSyncV2AccountScope == accountScope,
              saveState == .saved else { return nil }
        return AutoAdoptionExpectation(
            session: session,
            editGeneration: editGeneration,
            accountScope: accountScope
        )
    }

    func scheduleAutomaticAdoptionAfterCleanOpen(
        _ application: SyncV2Application,
        workID: WorkID
    ) {
        guard let projected = snapshotSyncState,
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
            expectedAccountScope: expectation.accountScope,
            resumesWorker: false
        )
    }
}
