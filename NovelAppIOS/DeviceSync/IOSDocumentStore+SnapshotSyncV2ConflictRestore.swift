import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    @discardableResult
    func restoreSnapshotSyncV2(snapshotID raw: String) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let app = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID,
              let expectedSession = currentDocumentSessionToken,
              let snapshotID = try? SnapshotID(rawValue: raw) else { return false }
        let account = snapshotSyncV2AccountScope
        return await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2AccountTransitionActive,
                  !isDocumentTransitionInProgress, syncV2KeepBothPendingWorkID == nil,
                  currentDocumentSessionToken == expectedSession,
                  matchesSyncAccount(account),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            isDocumentTransitionInProgress = true
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                isDocumentTransitionInProgress = false
            }
            do {
                return try await ConflictCoordinator(application: app).restoreAtPreparedBoundary(
                    host: self, workID: workID, snapshotID: snapshotID,
                    isCurrent: {
                        !self.isSyncV2AccountTransitionActive
                            && self.currentDocumentSessionToken == expectedSession
                            && self.matchesSyncAccount(account)
                    }, save: { await self.saveNow() },
                    install: { opened in
                        guard let value = opened.document else { return false }
                        return self.installSnapshotSyncV2Opened(opened, value: value)
                    }, project: { self.applySnapshotSyncV2State($0) }
                )
            } catch {
                snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
                return false
            }
        }
    }

    @discardableResult
    func resolveSnapshotSyncV2Conflict(
        using choice: SyncV2ConflictChoice,
        expectedSelection: IOSSnapshotSyncV2ConflictSelection
    ) async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive, !isSnapshotSyncInFlight,
              syncV2KeepBothPendingWorkID == nil,
              let app = snapshotSyncV2Application, startupState == .ready else { return false }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        return await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2RemoteAccountTransitionActive,
                  !isDocumentTransitionInProgress,
                  snapshotSyncV2DisplayedConflictSelection == expectedSelection,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            isDocumentTransitionInProgress = true
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                isDocumentTransitionInProgress = false
            }
            let context = WorkspaceOperationContext(
                workID: expectedSelection.workID, session: expectedSelection.session,
                account: expectedSelection.accountScope, editGeneration: expectedSelection.editGeneration
            )
            let port = WorkspaceConflictPort(
                isCurrent: {
                    !self.isSyncV2RemoteAccountTransitionActive
                        && self.currentDocumentSessionToken == expectedSelection.session
                        && self.matchesSyncAccount(expectedSelection.accountScope)
                }, isSaved: { self.conflictEditorIsSaved() },
                displayedState: { self.snapshotSyncState },
                freeze: { id in
                    self.syncV2KeepBothPendingWorkID = id
                    if id == nil {
                        self.clearKeepBothHandoff()
                    }
                }, retainHandoff: { self.syncV2KeepBothHandoff = $0 },
                installClone: { opened, _ in
                    await self.installKeepBothOpenedWork(opened, context: context)
                }, project: { self.applySnapshotSyncV2State($0) },
                complete: { choice, _ in
                    let adoption = choice == .useServer
                        ? AutoAdoptionExpectation(workID: expectedSelection.workID, session: expectedSelection.session,
                                                  account: expectedSelection.accountScope, editGeneration: expectedSelection.editGeneration)
                        : nil
                    self.startSnapshotSyncV2Reprojection(
                        app, workID: expectedSelection.workID, automaticAdoption: adoption,
                        expectedAccountScope: expectedSelection.accountScope, resumesWorker: true
                    )
                }
            )
            do {
                let resolved = try await ConflictCoordinator(application: app).resolveAtPreparedBoundary(
                    host: self, selection: WorkspaceConflictSelection(context: context, conflict: expectedSelection.conflict),
                    choice: choice, port: port
                )
                if !resolved, syncV2KeepBothPendingWorkID != nil,
                   syncV2ActiveWorkID == expectedSelection.workID,
                   matchesSyncAccount(expectedSelection.accountScope) {
                    operationErrorMessage = "両方を保持する作品を安全に開けませんでした。元の作品への書込みを保留しています。"
                }
                return resolved
            } catch {
                snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
                if syncV2KeepBothPendingWorkID != nil {
                    operationErrorMessage = "両方を保持する作品を安全に開けませんでした。元の作品への書込みを保留しています。"
                }
                return false
            }
        }
    }

    private func conflictEditorIsSaved() -> Bool {
        // Choice is local prepare only, never an implicit checkpoint.
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            guard let episodeID = selectedEpisodeID,
                  document.episode(episodeID)?.episode.content == text else {
                operationErrorMessage = "未保存の変更があります。保存後に競合を再選択してください。"
                return false
            }
        case .compositionInProgress:
            operationErrorMessage = "日本語入力を確定してから、競合を解決してください。"
            return false
        case .notActive: break
        }
        guard saveState == .saved else {
            operationErrorMessage = "未保存の変更があります。保存後に競合を再選択してください。"
            return false
        }
        return true
    }
}
