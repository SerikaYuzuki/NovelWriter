import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

extension IOSDocumentStore {
    @discardableResult
    func restoreSnapshotSyncV2(snapshotID raw: String) async -> Bool {
        guard !syncV2AccountTransitionInProgress,
              let app = snapshotSyncV2Application,
              let activeWorkID = syncV2ActiveWorkID,
              let expectedSession = currentDocumentSessionToken,
              let snapshotID = try? SnapshotID(rawValue: raw) else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  !syncV2AccountTransitionInProgress,
                  !isDocumentTransitionInProgress,
                  currentDocumentSessionToken == expectedSession,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            guard saveState == .saved else {
                operationErrorMessage = "未保存の変更があります。復元前に保存してください。"
                return false
            }
            var restored = false
            let transitioned = await performDocumentTransition {
                do {
                    let result = try await app.restore(
                        workID: activeWorkID, snapshotID: snapshotID
                    )
                    guard !syncV2AccountTransitionInProgress,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    applySnapshotSyncV2State(result.state)
                    let opened = try await app.openLocal(workID: activeWorkID)
                    guard !syncV2AccountTransitionInProgress,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          opened.workID == activeWorkID,
                          let value = opened.document,
                          installSnapshotSyncV2Opened(opened, value: value) else { return }
                    await refreshSnapshotSyncV2Projection(
                        workID: activeWorkID,
                        expectedAccountScope: expectedAccountScope
                    )
                    restored = true
                } catch {
                    if !syncV2AccountTransitionInProgress,
                       snapshotSyncV2AccountScope == expectedAccountScope {
                        snapshotSyncOutcome = .failed
                    }
                }
            }
            return transitioned && restored
        }
    }

    @discardableResult
    func resolveSnapshotSyncV2Conflict(
        using choice: SyncV2ConflictChoice,
        expectedSelection: IOSSnapshotSyncV2ConflictSelection
    ) async -> Bool {
        guard !syncV2AccountTransitionInProgress,
              let app = snapshotSyncV2Application,
              startupState == .ready,
              let activeWorkID = syncV2ActiveWorkID,
              let expectedSession = currentDocumentSessionToken else { return false }
        let expectedEditGeneration = localEditGeneration
        let expectedAccountScope = snapshotSyncV2AccountScope
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  !syncV2AccountTransitionInProgress,
                  !isDocumentTransitionInProgress,
                  currentDocumentSessionToken == expectedSession,
                  localEditGeneration == expectedEditGeneration,
                  selectionMatchesCurrentConflict(expectedSelection),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            isDocumentTransitionInProgress = true
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                isDocumentTransitionInProgress = false
            }

            do {
                guard let action = makeSnapshotSyncV2ConflictAction(
                    using: choice,
                    workID: activeWorkID,
                    expectedSession: expectedSession,
                    expectedEditGeneration: expectedEditGeneration
                ) else { return false }
                let workID = action.workID
                let newWorkID = action.newWorkID
                // Keep-both changes the editor's ownership immediately after
                // local preparation.  Stop writes to the source WorkID before
                // the worker can be resumed; otherwise an edit made while the
                // transport is stalled could republish the old work.
                if let newWorkID {
                    syncV2KeepBothPendingWorkID = newWorkID
                }
                defer {
                    if let newWorkID,
                       syncV2KeepBothPendingWorkID == newWorkID {
                        syncV2KeepBothPendingWorkID = nil
                    }
                }
                let result = try await app.resolveConflict(workID: workID, action: action)
                guard !syncV2AccountTransitionInProgress,
                      snapshotSyncV2AccountScope == expectedAccountScope,
                      currentDocumentSessionToken == expectedSession else { return false }
                guard acceptsSnapshotSyncV2ConflictResult(result.typedResult) else {
                    if choice == .keepBoth {
                        syncV2KeepBothPendingWorkID = nil
                    }
                    applySnapshotSyncV2State(result.state)
                    return false
                }
                if choice == .keepBoth {
                    // The shared application has already prepared and opened
                    // the clone in SQLite. Install that exact value while
                    // this document gate is still held; reopening by WorkID
                    // would add a second boundary and could race resume.
                    guard let newWorkID,
                          let opened = result.openedWork,
                          opened.workID == newWorkID,
                          let value = opened.document,
                          syncV2KeepBothPendingWorkID == opened.workID,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else {
                        operationErrorMessage = "両方を保持する作品を安全に開けませんでした。"
                        return false
                    }
                    guard installSnapshotSyncV2Opened(opened, value: value) else {
                        return false
                    }
                    let state = await app.uiState(workID: opened.workID)
                    guard !syncV2AccountTransitionInProgress,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2ActiveWorkID == opened.workID else { return false }
                    applySnapshotSyncV2State(state)
                } else {
                    applySnapshotSyncV2State(result.state)
                }
                // Resolution is queued locally.  The worker will perform the
                // network operation outside this UI call; reproject its
                // eventual conflict/adoption result without making this
                // action wait.
                let automaticAdoption = choice == .useServer
                    ? AutoAdoptionExpectation(
                        session: expectedSession,
                        editGeneration: expectedEditGeneration,
                        accountScope: expectedAccountScope
                    )
                    : nil
                startSnapshotSyncV2Reprojection(
                    app,
                    workID: workID,
                    automaticAdoption: automaticAdoption,
                    expectedAccountScope: expectedAccountScope,
                    resumesWorker: true
                )
                return true
            } catch {
                if choice == .keepBoth {
                    syncV2KeepBothPendingWorkID = nil
                }
                if snapshotSyncV2AccountScope == expectedAccountScope {
                    snapshotSyncOutcome = .failed
                }
                return false
            }
        }
    }

    private func selectionMatchesCurrentConflict(
        _ selection: IOSSnapshotSyncV2ConflictSelection
    ) -> Bool {
        selection.workID == syncV2ActiveWorkID
            && selection.session == currentDocumentSessionToken
            && selection.editGeneration <= localEditGeneration
            && selection.accountID == authSession?.accountID
            && selection.accountFence == authSession?.accountFence
            && selection.conflict == snapshotSyncConflict
    }

    private func makeSnapshotSyncV2ConflictAction(
        using choice: SyncV2ConflictChoice,
        workID: WorkID,
        expectedSession: IOSDocumentSessionToken,
        expectedEditGeneration: UInt64
    ) -> SyncV2ConflictAction? {
        // Conflict selection is a local prepare only.  Do not checkpoint
        // here: doing so creates a newer intent and makes the displayed
        // conflict stale while the user is choosing an action.  The editor
        // must already be saved; a dirty editor is sent back to the normal
        // save boundary and must select the conflict again.
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            guard let episodeID = selectedEpisodeID,
                  document.episode(episodeID)?.episode.content == text else {
                operationErrorMessage = "未保存の変更があります。保存後に競合を再選択してください。"
                return nil
            }
        case .compositionInProgress:
            operationErrorMessage = "日本語入力を確定してから、競合を解決してください。"
            return nil
        case .notActive: break
        }

        guard saveState == .saved,
              currentDocumentSessionToken == expectedSession,
              localEditGeneration == expectedEditGeneration else {
            operationErrorMessage = "未保存の変更があります。保存後に競合を再選択してください。"
            return nil
        }

        // The conflict projection was already verified and rendered from the
        // durable local inbox. Re-reading the server here would make the
        // button a network wait and could pair the choice with a newer
        // revision.
        guard let conflict = snapshotSyncConflict,
              let state = snapshotSyncState,
              state.workID == workID,
              state.conflict == conflict,
              case let .saved(generation, _) = state.localDurability,
              generation >= conflict.sourceGeneration else {
            operationErrorMessage = "競合情報が古くなりました。最新の状態を確認してから再選択してください。"
            return nil
        }
        let newWorkID = choice == .keepBoth ? WorkID(UUID()) : nil
        let newDocumentID = choice == .keepBoth ? DocumentID(UUID()) : nil
        return SyncV2ConflictAction(
            workID: workID, conflictID: conflict.conflictID,
            revision: conflict.revision, baseSnapshotID: conflict.baseSnapshotID,
            localSnapshotID: conflict.localSnapshotID, remoteSnapshotID: conflict.remoteSnapshotID,
            sourceGeneration: conflict.sourceGeneration, choice: choice,
            commandID: conflict.commandID,
            newWorkID: newWorkID, newDocumentID: newDocumentID
        )
    }
}
