import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

/// macOSの競合選択と安全なserver adoption。選択は既存SQLite世代を証明して
/// から行い、keep-bothは返却されたWorkIDを先にeditorへhandoffする。
extension AppState {
    /// Installs the local keep-both result before waking any transport lane.
    /// The shared application returns the prepared clone in the operation
    /// result; opening it again by WorkID would create a race with a worker
    /// and would make the returned local hand-off less explicit.
    @discardableResult
    func installKeepBothOpenedWork(
        _ opened: SyncV2OpenedWork,
        using application: SyncV2Application
    ) async -> Bool {
        guard let clone = opened.document else { return false }
        installV2Document(
            clone,
            workID: opened.workID,
            createdAt: opened.documentCreatedAt,
            attachments: opened.attachments,
            resources: opened.resources
        )
        snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
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
        guard permitsDocumentInteraction,
              let application = snapshotSyncV2Application else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard let sourceWorkID = currentSnapshotSyncV2WorkID else { return false }
            guard let state = await application.uiState(workID: sourceWorkID),
                  let conflict = state.conflict else { return false }
            // Conflict choice is not a second save button. The editor must
            // already be at a durable SQLite checkpoint whose generation is
            // the one presented by the conflict. If the user has typed since
            // that checkpoint, preserve the input and leave the conflict
            // pending for the next explicit save/retry boundary.
            guard saveState == .saved,
                  case let .saved(localGeneration, _) = state.localDurability,
                  localGeneration == conflict.sourceGeneration,
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
                newWorkID: choice == .keepBoth ? WorkID(UUID()) : nil,
                newDocumentID: choice == .keepBoth ? DocumentID(UUID()) : nil
            )
            do {
                let result = try await application.resolveConflict(
                    workID: sourceWorkID,
                    action: action
                )
                if choice == .keepBoth, let opened = result.openedWork {
                    // The clone is durable in SQLite as part of conflict
                    // preparation. Switch the editor to that WorkID before
                    // the original work's remote worker can acknowledge it;
                    // subsequent autosaves therefore cannot re-dirty the
                    // source conflict.
                    guard await installKeepBothOpenedWork(opened, using: application) else {
                        return false
                    }
                }
                await refreshSnapshotSyncV2UIState()
                if choice == .useServer, result.typedResult != .staleConflictAction {
                    scheduleAutomaticServerAdoption()
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
    private func scheduleAutomaticServerAdoption() {
        snapshotSyncAutoAdoptionTask?.cancel()
        let expectedSession = documentSessionToken
        snapshotSyncAutoAdoptionTask = Task { @MainActor [weak self] in
            defer { self?.snapshotSyncAutoAdoptionTask = nil }
            for _ in 0 ..< 150 {
                guard !Task.isCancelled, let self,
                      documentSessionToken == expectedSession,
                      startupState.isReady,
                      let application = snapshotSyncV2Application else { return }
                guard let workID = currentSnapshotSyncV2WorkID,
                      let state = await application.uiState(workID: workID) else {
                    return
                }
                switch state.remoteProgress {
                case .readyForSafeAdoption:
                    _ = await applySnapshotSyncV2ServerVersion()
                    return
                case .failed, .offline, .authenticationRequired,
                     .fenceChanged, .parkedDifferentAccount, .quarantined,
                     .retryable, .needsChoice, .receiptMismatch:
                    return
                case .idle, .noChanges, .pending, .syncing:
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
        guard let workID = currentSnapshotSyncV2WorkID else { return false }
        guard let application = snapshotSyncV2Application,
              let platformGate = snapshotSyncV2DocumentGate,
              let session = snapshotSyncV2Session else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentInteraction,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            do {
                // The editor boundary may have synchronously committed the
                // last NSTextView value. Drain that local revision before
                // taking the proof; no remote worker is awaited here.
                // A safe adoption must never create a fresh local SyncIntent
                // while proving the boundary. The editor must already be at
                // a committed local checkpoint; otherwise leave the verified
                // Inbox pending for an explicit retry after the next save.
                guard saveState == .saved,
                      let pending = try await application.pendingAdoption(workID: workID) else {
                    return false
                }
                guard hasCommittedEditorTextMatchingSelectedEpisode() else {
                    return false
                }
                let pendingIntentCleared = if let state = await application.uiState(workID: workID) {
                    state.lastTypedResult == .adoptionPending &&
                        state.remoteProgress == .readyForSafeAdoption(inboxID: pending.inboxID)
                } else {
                    false
                }
                guard pendingIntentCleared else { return false }
                try await platformGate.arm(
                    session: session,
                    expectedLocalVersion: pending.expectedLocalVersion,
                    proof: SyncV2SafeBoundaryProof(
                        editorGeneration: editorContentGeneration,
                        hasMarkedText: false,
                        hasUnsavedChanges: saveState != .saved,
                        pendingIntentCleared: pendingIntentCleared
                    )
                )
                let token = try await application.documentGateToken(for: session)
                let opened = try await application.applyStagedRemote(
                    at: SafeAdoptionBoundary(
                        workID: workID,
                        inboxID: pending.inboxID,
                        session: session,
                        gate: token
                    )
                )
                guard let adopted = opened.document else { return false }
                installV2Document(
                    adopted,
                    workID: opened.workID,
                    createdAt: opened.documentCreatedAt,
                    attachments: opened.attachments,
                    resources: opened.resources
                )
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                await platformGate.disarm(session: session)
                return false
            }
        }
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
        guard let workID = currentSnapshotSyncV2WorkID else { return false }
        guard permitsDocumentInteraction,
              let application = snapshotSyncV2Application else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            guard await saveNow() else { return false }
            do {
                _ = try await application.restore(workID: workID, snapshotID: snapshotID)
                // Restore commits a new local SQLite head immediately. Re-open
                // that head before returning so the editor and attachment list
                // reflect the restored bytes without waiting for the worker.
                let opened = try await application.open(workID: workID)
                guard let restored = opened.document else { return false }
                installV2Document(
                    restored,
                    workID: opened.workID,
                    createdAt: opened.documentCreatedAt,
                    attachments: opened.attachments,
                    resources: opened.resources
                )
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                return false
            }
        }
    }
}
