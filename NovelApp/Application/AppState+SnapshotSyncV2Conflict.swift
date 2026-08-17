import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

/// Immutable values captured when the conflict sheet is presented.  A choice
/// must never silently apply to a later WorkID/session/account or a newer CAS
/// projection after the sheet has been left open.
struct SnapshotSyncV2ConflictSelection: Hashable, Sendable {
    let workID: WorkID
    let documentSession: AppDocumentSessionToken
    let snapshotSession: NovelSyncV2Application.DocumentSessionToken
    let accountID: String?
    let accountFence: String?
    let accountScopeGeneration: UInt64
    let conflict: SyncV2ConflictProjection

    var accountScope: SnapshotSyncV2AccountScopeToken {
        SnapshotSyncV2AccountScopeToken(
            accountID: accountID,
            accountFence: accountFence,
            generation: accountScopeGeneration
        )
    }
}

/// macOSの競合選択と安全なserver adoption。選択は既存SQLite世代を証明して
/// から行い、keep-bothは返却されたWorkIDを先にeditorへhandoffする。
extension AppState {
    var snapshotSyncV2ConflictSelection: SnapshotSyncV2ConflictSelection? {
        guard let workID = currentSnapshotSyncV2WorkID,
              let snapshotSession = snapshotSyncV2Session,
              let conflict = snapshotSyncConflict,
              snapshotSession.workID == workID else { return nil }
        return SnapshotSyncV2ConflictSelection(
            workID: workID,
            documentSession: documentSessionToken,
            snapshotSession: snapshotSession,
            accountID: authSession?.accountID,
            accountFence: authSession?.accountFence,
            accountScopeGeneration: snapshotSyncV2AccountScopeGeneration,
            conflict: conflict
        )
    }

    private func matchesSnapshotSyncV2Identity(
        workID: WorkID,
        documentSession: AppDocumentSessionToken,
        snapshotSession: NovelSyncV2Application.DocumentSessionToken
    ) -> Bool {
        currentSnapshotSyncV2WorkID == workID
            && documentSessionToken == documentSession
            && snapshotSyncV2Session == snapshotSession
    }

    /// Installs the local keep-both result before waking any transport lane.
    /// The shared application returns the prepared clone in the operation
    /// result; opening it again by WorkID would create a race with a worker
    /// and would make the returned local hand-off less explicit.
    @discardableResult
    func installKeepBothOpenedWork(
        _ opened: SyncV2OpenedWork,
        using application: SyncV2Application,
        sourceSelection: SnapshotSyncV2ConflictSelection,
        expectedWorkID: WorkID?,
        expectedDocumentID: DocumentID?
    ) async -> Bool {
        guard let clone = opened.document else { return false }
        let newSession = await application.beginSession(workID: opened.workID)
        guard matchesSnapshotSyncV2Identity(
            workID: sourceSelection.workID,
            documentSession: sourceSelection.documentSession,
            snapshotSession: sourceSelection.snapshotSession
        ),
            matchesSnapshotSyncV2AccountScope(sourceSelection.accountScope),
            installV2Document(
                clone,
                workID: opened.workID,
                createdAt: opened.documentCreatedAt,
                attachments: opened.attachments,
                resources: opened.resources,
                expectedWorkID: expectedWorkID,
                expectedDocumentID: expectedDocumentID?.rawValue
            ) else { return false }
        snapshotSyncV2Session = newSession
        // Keep-both intentionally returns before waking transport. The
        // clone/session hand-off above is the safety boundary; only after it
        // is complete may the durable worker resume.
        Task { @MainActor [weak self] in
            try? await application.resumePending()
            await self?.refreshSnapshotSyncV2UIState()
            await self?.refreshSnapshotLibrary()
        }
        return true
    }

    @discardableResult
    func resolveSnapshotConflict(using choice: SyncV2ConflictChoice) async -> Bool {
        guard let application = snapshotSyncV2Application,
              let workID = currentSnapshotSyncV2WorkID,
              let snapshotSession = snapshotSyncV2Session else { return false }
        let conflict = if let snapshotSyncConflict {
            snapshotSyncConflict
        } else {
            await application.uiState(workID: workID)?.conflict
        }
        guard let conflict else { return false }
        let selection = SnapshotSyncV2ConflictSelection(
            workID: workID,
            documentSession: documentSessionToken,
            snapshotSession: snapshotSession,
            accountID: authSession?.accountID,
            accountFence: authSession?.accountFence,
            accountScopeGeneration: snapshotSyncV2AccountScopeGeneration,
            conflict: conflict
        )
        return await resolveSnapshotConflict(using: choice, selection: selection)
    }

    @discardableResult
    func resolveSnapshotConflict(
        using choice: SyncV2ConflictChoice,
        selection: SnapshotSyncV2ConflictSelection
    ) async -> Bool {
        guard permitsDocumentTransitionOperation,
              let application = snapshotSyncV2Application else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentTransitionOperation,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard matchesSnapshotSyncV2Identity(
                workID: selection.workID,
                documentSession: selection.documentSession,
                snapshotSession: selection.snapshotSession
            ),
                matchesSnapshotSyncV2AccountScope(selection.accountScope),
                let state = await application.uiState(workID: selection.workID) else { return false }
            guard matchesSnapshotSyncV2AccountScope(selection.accountScope),
                  state.conflict == selection.conflict else { return false }
            let sourceWorkID = selection.workID
            let conflict = selection.conflict
            // Conflict choice is not a second save button. The editor must
            // already be at a durable SQLite checkpoint whose generation is
            // the one presented by the conflict. If the user has typed since
            // that checkpoint, preserve the input and leave the conflict
            // pending for the next explicit save/retry boundary.
            guard saveState == .saved,
                  case let .saved(localGeneration, _) = state.localDurability,
                  localGeneration >= conflict.sourceGeneration,
                  hasCommittedEditorTextMatchingSelectedEpisode() else {
                operationMessage = "この端末に保存してから、競合の版を選んでください。"
                return false
            }
            let action = SyncV2ConflictAction(
                workID: sourceWorkID,
                conflictID: conflict.conflictID,
                revision: conflict.revision,
                baseSnapshotID: conflict.baseSnapshotID,
                localSnapshotID: conflict.localSnapshotID,
                remoteSnapshotID: conflict.remoteSnapshotID,
                sourceGeneration: conflict.sourceGeneration,
                choice: choice,
                commandID: conflict.commandID,
                newWorkID: choice == .keepBoth ? WorkID(UUID()) : nil,
                newDocumentID: choice == .keepBoth ? DocumentID(UUID()) : nil
            )
            do {
                let result = try await application.resolveConflict(
                    workID: sourceWorkID,
                    action: action
                )
                guard matchesSnapshotSyncV2Identity(
                    workID: selection.workID,
                    documentSession: selection.documentSession,
                    snapshotSession: selection.snapshotSession
                ), matchesSnapshotSyncV2AccountScope(selection.accountScope) else {
                    return false
                }
                if result.typedResult == .staleConflictAction {
                    await refreshSnapshotSyncV2UIState()
                    return false
                }
                if choice == .keepBoth, let opened = result.openedWork {
                    // The clone is durable in SQLite as part of conflict
                    // preparation. Switch the editor to that WorkID before
                    // the original work's remote worker can acknowledge it;
                    // subsequent autosaves therefore cannot re-dirty the
                    // source conflict.
                    guard matchesSnapshotSyncV2Identity(
                        workID: selection.workID,
                        documentSession: selection.documentSession,
                        snapshotSession: selection.snapshotSession
                    ),
                        matchesSnapshotSyncV2AccountScope(selection.accountScope),
                        await installKeepBothOpenedWork(
                            opened,
                            using: application,
                            sourceSelection: selection,
                            expectedWorkID: action.newWorkID,
                            expectedDocumentID: action.newDocumentID
                        ) else {
                        operationMessage = "競合の複製を検証できませんでした。元の作品は変更していません。"
                        return false
                    }
                }
                await refreshSnapshotSyncV2UIState()
                if choice == .useServer, result.typedResult != .staleConflictAction {
                    scheduleAutomaticServerAdoption(expectedAccountScope: selection.accountScope)
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// A server-choice conflict is one user operation. The worker may need to
    /// finish its receipt asynchronously, so keep polling the shared value
    /// projection and apply once it reaches the safe boundary. If the editor
    /// becomes dirty or the CAS changes, `applySnapshotSyncV2ServerVersion`
    /// returns false and the status control remains the explicit retry path.
    func scheduleAutomaticServerAdoption(
        expectedAccountScope: SnapshotSyncV2AccountScopeToken? = nil
    ) {
        snapshotSyncAutoAdoptionTask?.cancel()
        let expectedSession = documentSessionToken
        let accountScope = expectedAccountScope ?? snapshotSyncV2AccountScopeToken
        let operationToken = UUID()
        snapshotSyncV2AutoAdoptionToken = operationToken
        snapshotSyncAutoAdoptionTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.snapshotSyncV2AutoAdoptionToken == operationToken {
                    self.snapshotSyncV2AutoAdoptionToken = nil
                    self.snapshotSyncAutoAdoptionTask = nil
                }
            }
            for _ in 0 ..< 150 {
                guard !Task.isCancelled, let self,
                      snapshotSyncV2AutoAdoptionToken == operationToken,
                      matchesSnapshotSyncV2AccountScope(accountScope),
                      documentSessionToken == expectedSession,
                      startupState.isReady,
                      let application = snapshotSyncV2Application else { return }
                guard let workID = currentSnapshotSyncV2WorkID,
                      let state = await application.uiState(workID: workID) else {
                    return
                }
                switch state.remoteProgress {
                case .readyForSafeAdoption:
                    _ = await applySnapshotSyncV2ServerVersion(
                        expectedAccountScope: accountScope
                    )
                    return
                case .failed, .fenceChanged, .parkedDifferentAccount,
                     .quarantined, .needsChoice, .receiptMismatch:
                    return
                case .idle, .noChanges, .pending, .syncing, .offline,
                     .authenticationRequired, .retryable:
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// Server adoption is possible only after the editor operation gate has
    /// committed IME and unsaved state. SQLite performs the final generation
    /// and pending-intent CAS in `applyStagedRemote`.
    @discardableResult
    func applySnapshotSyncV2ServerVersion() async -> Bool {
        await applySnapshotSyncV2ServerVersion(
            expectedAccountScope: snapshotSyncV2AccountScopeToken
        )
    }

    @discardableResult
    private func applySnapshotSyncV2ServerVersion(
        expectedAccountScope: SnapshotSyncV2AccountScopeToken
    ) async -> Bool {
        guard let workID = currentSnapshotSyncV2WorkID,
              let expectedSnapshotSession = snapshotSyncV2Session,
              matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
        let expectedDocumentSession = documentSessionToken
        guard let application = snapshotSyncV2Application,
              let platformGate = snapshotSyncV2DocumentGate,
              expectedSnapshotSession.workID == workID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  matchesSnapshotSyncV2Identity(
                      workID: workID,
                      documentSession: expectedDocumentSession,
                      snapshotSession: expectedSnapshotSession
                  ),
                  matchesSnapshotSyncV2AccountScope(expectedAccountScope),
                  permitsDocumentTransitionOperation,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            let session = expectedSnapshotSession
            do {
                // The editor boundary may have synchronously committed the
                // last NSTextView value. Drain that local revision before
                // taking the proof; no remote worker is awaited here.
                // A safe adoption must never create a fresh local SyncIntent
                // while proving the boundary. The editor must already be at
                // a committed local checkpoint; otherwise leave the verified
                // Inbox pending for an explicit retry after the next save.
                guard let pending = try await pendingSnapshotSyncV2ServerAdoption(
                    application: application,
                    workID: workID,
                    expectedAccountScope: expectedAccountScope
                ) else {
                    return false
                }
                try await platformGate.arm(
                    session: session,
                    expectedLocalVersion: pending.expectedLocalVersion,
                    proof: SyncV2SafeBoundaryProof(
                        editorGeneration: editorContentGeneration,
                        hasMarkedText: false,
                        hasUnsavedChanges: saveState != .saved,
                        pendingIntentCleared: true
                    )
                )
                guard matchesSnapshotSyncV2Identity(
                    workID: workID,
                    documentSession: expectedDocumentSession,
                    snapshotSession: expectedSnapshotSession
                ), matchesSnapshotSyncV2AccountScope(expectedAccountScope) else {
                    await platformGate.disarm(session: session)
                    return false
                }
                let token = try await application.documentGateToken(for: session)
                guard matchesSnapshotSyncV2Identity(
                    workID: workID,
                    documentSession: expectedDocumentSession,
                    snapshotSession: expectedSnapshotSession
                ), matchesSnapshotSyncV2AccountScope(expectedAccountScope) else {
                    await platformGate.disarm(session: session)
                    return false
                }
                let opened = try await application.applyStagedRemote(
                    at: SafeAdoptionBoundary(
                        workID: workID,
                        inboxID: pending.inboxID,
                        session: session,
                        gate: token
                    )
                )
                #if FUMINIWA_TEST_COMPOSITION
                await snapshotSyncV2AfterStagedRemoteOverride?()
                #endif
                guard matchesSnapshotSyncV2Identity(
                    workID: workID,
                    documentSession: expectedDocumentSession,
                    snapshotSession: expectedSnapshotSession
                ), matchesSnapshotSyncV2AccountScope(expectedAccountScope) else {
                    await platformGate.disarm(session: session)
                    return false
                }
                guard opened.document != nil else {
                    await platformGate.disarm(session: session)
                    return false
                }
                await platformGate.disarm(session: session)
                guard await installSnapshotSyncV2ServerAdoption(
                    opened,
                    application: application,
                    expectedDocumentSession: expectedDocumentSession,
                    expectedSnapshotSession: expectedSnapshotSession,
                    expectedAccountScope: expectedAccountScope
                ) else {
                    operationMessage = "サーバーの作品データを検証できませんでした。端末の表示は変更していません。"
                    return false
                }
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                await platformGate.disarm(session: session)
                return false
            }
        }
    }

    private func pendingSnapshotSyncV2ServerAdoption(
        application: SyncV2Application,
        workID: WorkID,
        expectedAccountScope: SnapshotSyncV2AccountScopeToken
    ) async throws -> SyncV2PendingAdoption? {
        guard matchesSnapshotSyncV2AccountScope(expectedAccountScope),
              saveState == .saved,
              let pending = try await application.pendingAdoption(workID: workID),
              matchesSnapshotSyncV2AccountScope(expectedAccountScope),
              hasCommittedEditorTextMatchingSelectedEpisode(),
              let state = await application.uiState(workID: workID),
              matchesSnapshotSyncV2AccountScope(expectedAccountScope),
              state.lastTypedResult == .adoptionPending,
              state.remoteProgress == .readyForSafeAdoption(inboxID: pending.inboxID) else {
            return nil
        }
        return pending
    }

    private func installSnapshotSyncV2ServerAdoption(
        _ opened: SyncV2OpenedWork,
        application: SyncV2Application,
        expectedDocumentSession: AppDocumentSessionToken,
        expectedSnapshotSession: NovelSyncV2Application.DocumentSessionToken,
        expectedAccountScope: SnapshotSyncV2AccountScopeToken
    ) async -> Bool {
        guard let adopted = opened.document else { return false }
        let workID = expectedSnapshotSession.workID
        let newSession = await application.beginSession(workID: opened.workID)
        guard matchesSnapshotSyncV2Identity(
            workID: workID,
            documentSession: expectedDocumentSession,
            snapshotSession: expectedSnapshotSession
        ), matchesSnapshotSyncV2AccountScope(expectedAccountScope),
        installV2Document(
            adopted,
            workID: opened.workID,
            createdAt: opened.documentCreatedAt,
            attachments: opened.attachments,
            resources: opened.resources,
            expectedWorkID: workID,
            expectedDocumentID: expectedDocumentSession.documentID
        ) else {
            return false
        }
        snapshotSyncV2Session = newSession
        return true
    }

    /// A captured editor value is only a safe proof when it belongs to the
    /// active episode and is exactly the model value already represented by
    /// the committed SQLite generation. A delayed save-state callback must
    /// not let a newer NSTextView value be hidden by server adoption.
    private func hasCommittedEditorTextMatchingSelectedEpisode() -> Bool {
        switch activeCommittedTextCapture() {
        case .notActive:
            // A global conflict sheet can be opened while no editor surface
            // owns the first responder (for example, Characters or Settings).
            // There is no text surface to be stale in this case.
            return true
        case .compositionInProgress:
            return false
        case let .captured(text):
            guard workspaceSelection.section == .structure,
                  let selectedChapterID,
                  let selectedEpisodeID,
                  let selectedEpisode = document.episode(selectedEpisodeID),
                  selectedEpisode.chapterID == selectedChapterID else {
                return false
            }
            return text == selectedEpisode.episode.content
        }
    }

    @discardableResult
    func restoreSnapshotV2(snapshotID: SnapshotID) async -> Bool {
        guard let workID = currentSnapshotSyncV2WorkID,
              let expectedSnapshotSession = snapshotSyncV2Session,
              expectedSnapshotSession.workID == workID else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScopeToken
        guard permitsDocumentTransitionOperation,
              let application = snapshotSyncV2Application else { return false }
        let expectedDocumentSession = documentSessionToken
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  matchesSnapshotSyncV2Identity(
                      workID: workID,
                      documentSession: expectedDocumentSession,
                      snapshotSession: expectedSnapshotSession
                  ),
                  matchesSnapshotSyncV2AccountScope(expectedAccountScope),
                  permitsDocumentTransitionOperation,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            let gateDocumentSession = documentSessionToken
            let gateWorkID = currentSnapshotSyncV2WorkID
            let gateSnapshotSession = snapshotSyncV2Session
            guard gateWorkID == workID,
                  gateDocumentSession == expectedDocumentSession,
                  gateSnapshotSession == expectedSnapshotSession,
                  matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
            guard await saveNow() else { return false }
            do {
                guard matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
                _ = try await application.restore(workID: workID, snapshotID: snapshotID)
                guard matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
                // Restore commits a new local SQLite head immediately. Re-open
                // that head before returning so the editor and attachment list
                // reflect the restored bytes without waiting for the worker.
                let opened = try await application.openLocal(workID: workID)
                guard matchesSnapshotSyncV2Identity(
                    workID: workID,
                    documentSession: expectedDocumentSession,
                    snapshotSession: expectedSnapshotSession
                ), matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
                guard let restored = opened.document else { return false }
                let newSession = await application.beginSession(workID: opened.workID)
                guard matchesSnapshotSyncV2Identity(
                    workID: workID,
                    documentSession: expectedDocumentSession,
                    snapshotSession: expectedSnapshotSession
                ),
                    matchesSnapshotSyncV2AccountScope(expectedAccountScope),
                    installV2Document(
                        restored,
                        workID: opened.workID,
                        createdAt: opened.documentCreatedAt,
                        attachments: opened.attachments,
                        resources: opened.resources,
                        expectedWorkID: workID,
                        expectedDocumentID: expectedDocumentSession.documentID
                    ) else {
                    operationMessage = "復元した作品データを検証できませんでした。端末の表示は変更していません。"
                    return false
                }
                snapshotSyncV2Session = newSession
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                return false
            }
        }
    }
}
