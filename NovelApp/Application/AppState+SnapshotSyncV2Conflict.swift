import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelWorkspace

/// Immutable values captured when the conflict sheet is presented.  A choice
/// must never silently apply to a later WorkID/session/account or a newer CAS
/// projection after the sheet has been left open.
struct SnapshotSyncV2ConflictSelection: Hashable, Sendable {
    let workID: WorkID
    let documentSession: WorkspaceSessionToken
    let snapshotSession: NovelSyncV2Application.DocumentSessionToken
    let accountScope: WorkspaceAccountScope
    let editGeneration: UInt64
    let conflict: SyncV2ConflictProjection
}

/// macOSの競合選択と安全なserver adoption。選択は既存SQLite世代を証明して
/// から行い、keep-bothは返却されたWorkIDを先にeditorへhandoffする。
extension AppState {
    var snapshotSyncV2ConflictSelection: SnapshotSyncV2ConflictSelection? {
        guard let workID = currentSnapshotSyncV2WorkID,
              let snapshotSession = snapshotSyncV2Session,
              let conflict = workspaceModel.syncConflict,
              snapshotSession.workID == workID else { return nil }
        return SnapshotSyncV2ConflictSelection(
            workID: workID,
            documentSession: workspaceModel.documentSessionToken,
            snapshotSession: snapshotSession,
            accountScope: snapshotSyncV2AccountScopeToken,
            editGeneration: workspaceModel.editGeneration,
            conflict: conflict
        )
    }

    private func matchesSnapshotSyncV2Identity(
        workID: WorkID,
        documentSession: WorkspaceSessionToken,
        snapshotSession: NovelSyncV2Application.DocumentSessionToken
    ) -> Bool {
        matchesSyncOperation(WorkspaceOperationContext(
            workID: workID, session: documentSession,
            account: snapshotSyncV2AccountScopeToken, editGeneration: nil
        )) && snapshotSyncV2Session == snapshotSession
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
        #if FUMINIWA_TEST_COMPOSITION
        await snapshotSyncV2BeforeKeepBothInstallOverride?()
        if let snapshotSyncV2KeepBothInstallOverride {
            guard await snapshotSyncV2KeepBothInstallOverride() else { return false }
        }
        #endif
        let newSession = await application.beginSession(workID: opened.workID)
        guard matchesSnapshotSyncV2Identity(
            workID: sourceSelection.workID,
            documentSession: sourceSelection.documentSession,
            snapshotSession: sourceSelection.snapshotSession
        ),
            matchesSnapshotSyncV2AccountScope(sourceSelection.accountScope),
            workspaceModel.editGeneration == sourceSelection.editGeneration,
            workspaceModel.keepBothPendingWorkID == opened.workID,
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
        return true
    }

    @discardableResult
    func resolveSnapshotConflict(using choice: SyncV2ConflictChoice) async -> Bool {
        guard let selection = snapshotSyncV2ConflictSelection else { return false }
        return await resolveSnapshotConflict(using: choice, selection: selection)
    }

    @discardableResult
    func resolveSnapshotConflict(
        using choice: SyncV2ConflictChoice,
        selection: SnapshotSyncV2ConflictSelection
    ) async -> Bool {
        guard permitsDocumentTransitionOperation, workspaceModel.keepBothPendingWorkID == nil,
              let application = snapshotSyncV2Application else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentTransitionOperation,
                  snapshotSyncV2ConflictSelection == selection,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            workspaceModel.isDocumentTransitionInProgress = true
            defer { workspaceModel.isDocumentTransitionInProgress = false }
            let context = WorkspaceOperationContext(
                workID: selection.workID, session: selection.documentSession,
                account: selection.accountScope, editGeneration: selection.editGeneration
            )
            let port = WorkspaceConflictPort(
                isCurrent: {
                    self.matchesSnapshotSyncV2Identity(
                        workID: selection.workID, documentSession: selection.documentSession,
                        snapshotSession: selection.snapshotSession
                    ) && self.matchesSnapshotSyncV2AccountScope(selection.accountScope)
                }, isSaved: {
                    let saved = self.workspaceModel.saveState == .saved && self.hasCommittedEditorTextMatchingSelectedEpisode()
                    if !saved {
                        self.operationMessage = "この端末に保存してから、競合の版を選んでください。"
                    }
                    return saved
                }, displayedState: { self.workspaceModel.syncUIState },
                freeze: { id in
                    self.workspaceModel.keepBothPendingWorkID = id
                    if id == nil {
                        self.clearKeepBothHandoff()
                    }
                }, retainHandoff: { handoff in
                    self.workspaceModel.keepBothHandoff = handoff
                    self.syncV2KeepBothSourceSelection = selection
                },
                installClone: { opened, action in
                    await self.installKeepBothOpenedWork(
                        opened, using: application, sourceSelection: selection,
                        expectedWorkID: action.newWorkID, expectedDocumentID: action.newDocumentID
                    )
                }, project: { self.applySnapshotSyncV2State($0) },
                complete: { choice, _ in
                    if choice == .keepBoth {
                        self.resumeKeepBothTransport(application)
                    } else if choice == .useServer {
                        self.scheduleAutomaticServerAdoption(expectedAccountScope: selection.accountScope)
                    }
                }
            )
            do {
                let resolved = try await ConflictCoordinator(application: application).resolveAtPreparedBoundary(
                    host: self, selection: WorkspaceConflictSelection(context: context, conflict: selection.conflict),
                    choice: choice, port: port
                )
                if !resolved, workspaceModel.keepBothPendingWorkID != nil,
                   currentSnapshotSyncV2WorkID == selection.workID,
                   matchesSnapshotSyncV2AccountScope(selection.accountScope) {
                    operationMessage = "競合の複製を安全に開けませんでした。元の作品への書込みを保留しています。"
                }
                return resolved
            } catch {
                if workspaceModel.keepBothPendingWorkID != nil {
                    operationMessage = "競合の複製を安全に開けませんでした。元の作品への書込みを保留しています。"
                }
                return false
            }
        }
    }

    /// A server-choice conflict is one user operation. The worker may need to
    /// finish its receipt asynchronously, so subscribe to the shared value
    /// projection and apply once it reaches the safe boundary. If the editor
    /// becomes dirty or the CAS changes, `applySnapshotSyncV2ServerVersion`
    /// returns false and the status control remains the explicit retry path.
    func scheduleAutomaticServerAdoption(
        expectedAccountScope: WorkspaceAccountScope? = nil
    ) {
        // Reprojection may be requested by several observers of the same
        // ready Inbox. Keep its owner alive through the safe-adoption awaits;
        // document/account transitions retire it explicitly.
        guard snapshotSyncAutoAdoptionTask == nil else { return }
        let expectedSession = workspaceModel.documentSessionToken
        let accountScope = expectedAccountScope ?? snapshotSyncV2AccountScopeToken
        let operationToken = syncSessionController.beginReprojection()
        snapshotSyncAutoAdoptionTask = Task { @MainActor [weak self] in
            defer {
                self?.syncSessionController.finishReprojection(owner: operationToken)
            }
            guard let application = self?.snapshotSyncV2Application,
                  let observedWorkID = self?.currentSnapshotSyncV2WorkID else { return }
            guard let self else { return }
            await AdoptionCoordinator(application: application).reproject(
                host: self, workID: observedWorkID,
                isCurrent: {
                    self.snapshotSyncV2AutoAdoptionToken == operationToken
                        && self.matchesSnapshotSyncV2AccountScope(accountScope)
                        && self.workspaceModel.documentSessionToken == expectedSession
                        && self.startupState.isReady && self.snapshotSyncV2Application === application
                }, receive: { state in
                    guard let state else { return false }
                    switch state.remoteProgress {
                    case .readyForSafeAdoption:
                        guard self.workspaceModel.saveState == .saved, self.hasCommittedEditorTextMatchingSelectedEpisode() else { return false }
                        _ = await self.applySnapshotSyncV2ServerVersion(expectedAccountScope: accountScope, automatically: true)
                        return false
                    case .failed, .fenceChanged, .parkedDifferentAccount,
                         .quarantined, .needsChoice, .receiptMismatch:
                        return false
                    case .idle, .noChanges, .pending, .syncing, .offline,
                         .authenticationRequired, .retryable:
                        return true
                    }
                }
            )
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
        expectedAccountScope: WorkspaceAccountScope,
        automatically: Bool = false
    ) async -> Bool {
        guard let workID = currentSnapshotSyncV2WorkID,
              let expectedSnapshotSession = snapshotSyncV2Session,
              matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
        let expectedDocumentSession = workspaceModel.documentSessionToken
        guard let application = snapshotSyncV2Application,
              snapshotSyncV2DocumentGate != nil,
              expectedSnapshotSession.workID == workID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard !Task.isCancelled, let self,
                  matchesSnapshotSyncV2Identity(
                      workID: workID,
                      documentSession: expectedDocumentSession,
                      snapshotSession: expectedSnapshotSession
                  ),
                  matchesSnapshotSyncV2AccountScope(expectedAccountScope),
                  permitsDocumentTransitionOperation,
                  hasCommittedEditorTextMatchingSelectedEpisode(),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            workspaceModel.isDocumentTransitionInProgress = true
            defer { workspaceModel.isDocumentTransitionInProgress = false }
            return await adoptSnapshotSyncV2AtPreparedBoundary(
                application: application,
                expectedDocumentSession: expectedDocumentSession,
                expectedSnapshotSession: expectedSnapshotSession,
                expectedAccountScope: expectedAccountScope,
                automatically: automatically
            )
        }
    }

    /// The caller holds the document operation gate and the committed editor
    /// boundary until this adoption and its attempt cleanup have finished.
    private func adoptSnapshotSyncV2AtPreparedBoundary(
        application: SyncV2Application,
        expectedDocumentSession: WorkspaceSessionToken,
        expectedSnapshotSession: NovelSyncV2Application.DocumentSessionToken,
        expectedAccountScope: WorkspaceAccountScope,
        automatically: Bool
    ) async -> Bool {
        guard let platformGate = snapshotSyncV2DocumentGate else { return false }
        let workID = expectedSnapshotSession.workID
        let session = expectedSnapshotSession
        var coordinator = AdoptionCoordinator(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        coordinator.applyStaged = { boundary in
            let opened = try await application.applyStagedRemote(at: boundary)
            await self.snapshotSyncV2AfterStagedRemoteOverride?()
            return opened
        }
        #endif
        let port = WorkspaceAdoptionPort(
            isCurrent: {
                self.matchesSnapshotSyncV2Identity(workID: workID, documentSession: expectedDocumentSession,
                                                   snapshotSession: expectedSnapshotSession)
                    && self.matchesSnapshotSyncV2AccountScope(expectedAccountScope)
                    && self.workspaceModel.saveState == .saved && self.hasCommittedEditorTextMatchingSelectedEpisode()
            },
            session: { _ in session },
            arm: { session, pending, _ in
                try await platformGate.arm(
                    session: session, expectedLocalVersion: pending.expectedLocalVersion,
                    proof: SyncV2SafeBoundaryProof(
                        editorGeneration: self.workspaceModel.editorContentGeneration,
                        hasMarkedText: self.activeCommittedTextCapture() == .compositionInProgress,
                        hasUnsavedChanges: self.workspaceModel.saveState != .saved, pendingIntentCleared: true
                    )
                )
            }, disarm: { await platformGate.disarm(session: $0) },
            claim: { !automatically || self.claimAutomaticAdoption($0, account: expectedAccountScope) },
            finishAttempt: { pending, failed in
                // Mac retries invalidated/cancelled boundaries, but retains actual failures.
                if automatically, !failed {
                    self.workspaceModel.automaticAdoptionAttempts[expectedAccountScope]?[workID]?.remove(pending.inboxID)
                }
            }, install: { opened in
                let installed = await self.installSnapshotSyncV2ServerAdoption(
                    opened, application: application, expectedDocumentSession: expectedDocumentSession,
                    expectedSnapshotSession: expectedSnapshotSession, expectedAccountScope: expectedAccountScope
                )
                if !installed, self.matchesSnapshotSyncV2Identity(
                    workID: workID, documentSession: expectedDocumentSession, snapshotSession: expectedSnapshotSession
                ), self.matchesSnapshotSyncV2AccountScope(expectedAccountScope) {
                    self.operationMessage = "サーバーの作品データを検証できませんでした。端末の表示は変更していません。"
                }
                return installed
            }, project: { self.applySnapshotSyncV2State($0) }
        )
        do {
            return try await coordinator.adoptAtPreparedBoundary(host: self, workID: workID, port: port)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  matchesSnapshotSyncV2Identity(workID: workID, documentSession: expectedDocumentSession,
                                                snapshotSession: expectedSnapshotSession),
                  matchesSnapshotSyncV2AccountScope(expectedAccountScope) else { return false }
            reportSnapshotSyncV2OpenFailure(error)
            return false
        }
    }

    private func installSnapshotSyncV2ServerAdoption(
        _ opened: SyncV2OpenedWork,
        application: SyncV2Application,
        expectedDocumentSession: WorkspaceSessionToken,
        expectedSnapshotSession: NovelSyncV2Application.DocumentSessionToken,
        expectedAccountScope: WorkspaceAccountScope
    ) async -> Bool {
        guard let adopted = opened.document else { return false }
        let retainedEpisode = workspaceModel.selectedEpisodeID.flatMap { adopted.episode($0) }
        let retainedChapter = adopted.chapters.first { $0.id == workspaceModel.selectedChapterID }
        let workID = expectedSnapshotSession.workID
        let newSession = await application.beginSession(workID: opened.workID)
        guard matchesSnapshotSyncV2Identity(
            workID: workID,
            documentSession: expectedDocumentSession,
            snapshotSession: expectedSnapshotSession
        ), matchesSnapshotSyncV2AccountScope(expectedAccountScope), opened.workID == workID else {
            return false
        }
        // A publish receipt can advance the snapshot lineage without changing
        // the work. Reinstalling that echo resets the editor key, selection and
        // Undo history even though there is no new content to display.
        if matchesInstalledSnapshotSyncV2Content(opened) {
            snapshotSyncV2Session = newSession
            return true
        }
        guard installV2Document(
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
        workspaceModel.selectedChapterID = retainedEpisode?.chapterID ?? retainedChapter?.id ?? adopted.chapters.first?.id
        workspaceModel.selectedEpisodeID = retainedEpisode?.episode.id ?? retainedChapter?.episodes.first?.id ?? adopted.chapters.first?.episodes.first?.id
        snapshotSyncV2Session = newSession
        return true
    }

    private func matchesInstalledSnapshotSyncV2Content(_ opened: SyncV2OpenedWork) -> Bool {
        guard let mirror = try? SyncV2PortableMetadata.splitLocalMirrorResources(opened.resources) else { return false }
        return opened.document == workspaceModel.document
            && opened.attachments == snapshotSyncV2Attachments
            && mirror.resources == snapshotSyncV2Resources
            && mirror.portableCreatedAt == snapshotSyncV2PortableCreatedAt
            && Self.normalizedSnapshotSyncV2Date(opened.documentCreatedAt) == snapshotSyncV2DocumentCreatedAt
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
                  let selectedChapterID = workspaceModel.selectedChapterID,
                  let selectedEpisodeID = workspaceModel.selectedEpisodeID,
                  let selectedEpisode = workspaceModel.document.episode(selectedEpisodeID),
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
        let expectedDocumentSession = workspaceModel.documentSessionToken
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
            workspaceModel.isDocumentTransitionInProgress = true
            defer { workspaceModel.isDocumentTransitionInProgress = false }
            do {
                return try await ConflictCoordinator(application: application).restoreAtPreparedBoundary(
                    host: self, workID: workID, snapshotID: snapshotID,
                    isCurrent: {
                        self.matchesSnapshotSyncV2Identity(
                            workID: workID, documentSession: expectedDocumentSession,
                            snapshotSession: expectedSnapshotSession
                        ) && self.matchesSnapshotSyncV2AccountScope(expectedAccountScope)
                    }, save: { await self.saveNow() },
                    install: { opened in
                        guard let restored = opened.document else { return false }
                        let context = self.operationContext
                        let newSession = await application.beginSession(workID: opened.workID)
                        guard context.isCurrent(self.operationContext),
                              self.snapshotSyncV2Session == expectedSnapshotSession,
                              self.installV2Document(
                                  restored, workID: opened.workID, createdAt: opened.documentCreatedAt,
                                  attachments: opened.attachments, resources: opened.resources,
                                  expectedWorkID: workID, expectedDocumentID: expectedDocumentSession.documentID
                              ) else {
                            self.operationMessage = "復元した作品データを検証できませんでした。端末の表示は変更していません。"
                            return false
                        }
                        self.snapshotSyncV2Session = newSession
                        return true
                    }, project: { self.applySnapshotSyncV2State($0) }
                )
            } catch {
                return false
            }
        }
    }
}
