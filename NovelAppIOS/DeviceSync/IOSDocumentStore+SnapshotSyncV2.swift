import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

private struct AutoAdoptionExpectation: Sendable {
    let session: IOSDocumentSessionToken
    let editGeneration: UInt64
    let accountScope: IOSSnapshotSyncV2AccountScope
}

enum IOSSnapshotSyncOutcome: Equatable, Sendable {
    case notStarted, offline, idle, pending, syncing, conflict, failed
}

func acceptsSnapshotSyncV2ConflictResult(_ result: SyncV2TypedResult) -> Bool {
    switch result {
    case .queued, .noChanges: true
    default: false
    }
}

func acceptsSnapshotSyncV2RemoteOnlyOpen(
    _ opened: SyncV2OpenedWork,
    requestedWorkID: WorkID
) -> Bool {
    opened.workID == requestedWorkID
}

extension IOSDocumentStore {
    /// Retires asynchronous remote-only work before a new document operation
    /// can change the session. The task itself must not clear a newer task's
    /// owner slot from its defer block.
    func cancelSnapshotSyncV2BackgroundOperations() {
        snapshotSyncV2RemoteOnlyOpenToken = nil
        snapshotSyncV2RemoteOnlyOpenTask?.cancel()
        snapshotSyncV2RemoteOnlyOpenTask = nil
        snapshotSyncV2RemoteOnlyReadyWorkID = nil
        snapshotSyncV2ReprojectionToken = nil
        snapshotSyncV2ReprojectionTask?.cancel()
        snapshotSyncV2ReprojectionTask = nil
    }

    func invalidateSnapshotSyncV2AccountOperations() {
        cancelSnapshotSyncV2BackgroundOperations()
        syncV2KeepBothPendingWorkID = nil
        libraryRefreshGeneration &+= 1
        historyRefreshGeneration &+= 1
        syncV2RemoteCatalogIsLoading = false
        advanceDocumentSessionGeneration()
    }

    @discardableResult
    func configureSnapshotSyncV2() async -> Bool {
        if snapshotSyncV2Application != nil {
            return true
        }
        if let task = snapshotSyncV2ConfigurationTask {
            await task.value
            return snapshotSyncV2Application != nil
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { snapshotSyncV2ConfigurationTask = nil }
            do {
                #if FUMINIWA_TEST_COMPOSITION
                guard case let .test(configuration) = runtimeComposition else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                let key = libraryRoot.standardizedFileURL
                if let cached = Self.testRuntimeApplications[key] {
                    snapshotSyncV2Application = cached
                } else {
                    let selectedConfiguration: TestRuntimeConfiguration
                    if let cachedConfiguration = Self.testRuntimeConfigurations[key] {
                        selectedConfiguration = cachedConfiguration
                    } else {
                        Self.testRuntimeConfigurations[key] = configuration
                        selectedConfiguration = configuration
                    }
                    let application = try await SnapshotSyncV2Runtime.makeApplication(
                        mode: .test(selectedConfiguration)
                    )
                    Self.testRuntimeApplications[key] = application
                    snapshotSyncV2Application = application
                }
                #else
                guard case .production = runtimeComposition else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
                if let configuration = try? ProductionRuntimeConfiguration(
                    origin: environment.syncServerURL.flatMap { try? ProductionHTTPSOrigin(url: $0) },
                    vault: makeProductionAuthVault(),
                    documentGate: snapshotSyncV2DocumentGate,
                    clientVersion: "0.1.0", clientPlatform: .ios
                ) {
                    snapshotSyncV2Application = try await SnapshotSyncV2Runtime.makeApplication(
                        mode: .production(configuration)
                    )
                } else {
                    snapshotSyncV2Application = nil
                }
                #endif
            } catch {
                snapshotSyncV2Application = nil
            }
        }
        snapshotSyncV2ConfigurationTask = task
        await task.value
        return snapshotSyncV2Application != nil
    }

    #if !FUMINIWA_TEST_COMPOSITION
    private func makeProductionAuthVault() -> (any AuthSessionVault)? {
        #if canImport(Security)
        KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync.ios")
        #else
        nil
        #endif
    }
    #endif

    @discardableResult
    func checkpointSnapshotSyncV2(
        _ value: NovelDocument,
        reason: SyncV2CheckpointReason = .autosave,
        resources: [PortableResource]? = nil
    ) async -> Bool {
        guard let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        do {
            guard let syncAttachments = currentV2Attachments() else {
                operationErrorMessage = "資料の本文を読み込めないため、端末への保存を中止しました。"
                snapshotSyncOutcome = .failed
                saveState = .failed
                return false
            }
            let localResources: [PortableResource]?
            do {
                localResources = if let resources {
                    try SyncV2PortableMetadata.resourcesForLocalMirror(
                        resources,
                        portableCreatedAt: syncV2PortableCreatedAt
                    )
                } else {
                    nil
                }
            } catch {
                operationErrorMessage = "portable metadataを安全に保存できないため、端末への保存を中止しました。"
                snapshotSyncOutcome = .failed
                saveState = .failed
                return false
            }
            let result = try await application.checkpoint(
                workID: workID, document: value, reason: reason,
                documentCreatedAt: documentCreatedAt,
                attachments: syncAttachments,
                resources: localResources
            )
            snapshotSyncOutcome = result.typedResult == .noChanges ? .idle : .pending
            saveState = .saved
            return true
        } catch {
            snapshotSyncOutcome = .failed
            saveState = .failed
            return false
        }
    }

    func resumeSnapshotSyncV2() async {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application else { return }
        let resumedWorkID = syncV2ActiveWorkID
        let expectedAccountScope = snapshotSyncV2AccountScope
        let automaticAdoption = resumedWorkID.flatMap {
            automaticAdoptionExpectation(
                for: $0,
                validatingEditorSurface: true
            )
        }
        // resumePending only wakes the durable worker.  Keep lifecycle/UI
        // non-blocking, then observe the actor's projected terminal state so
        // conflict/adoption/status changes become visible after the worker.
        startSnapshotSyncV2Reprojection(
            application,
            workID: resumedWorkID,
            automaticAdoption: automaticAdoption,
            expectedAccountScope: expectedAccountScope,
            resumesWorker: true
        )
    }

    @discardableResult
    func synchronizeSnapshotSyncV2() async -> Bool {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let result = try await application.synchronize(workID: workID)
            guard !syncV2AccountTransitionInProgress,
                  syncV2ActiveWorkID == workID,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            applySnapshotSyncV2State(result.state)
            return true
        } catch {
            if !syncV2AccountTransitionInProgress,
               syncV2ActiveWorkID == workID,
               snapshotSyncV2AccountScope == expectedAccountScope {
                snapshotSyncOutcome = .offline
            }
            return false
        }
    }

    /// Adopt a verified remote resolution only after the iOS document gate,
    /// IME boundary, editor generation, and local pending intent are safe.
    @discardableResult
    func adoptPendingSnapshotSyncV2(
        expectedSession: IOSDocumentSessionToken? = nil,
        expectedEditGeneration: UInt64? = nil,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope? = nil
    ) async -> Bool {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application,
              startupState == .ready,
              let activeWorkID = syncV2ActiveWorkID,
              let expectedSession = expectedSession ?? currentDocumentSessionToken else {
            return false
        }
        let expectedEditGeneration = expectedEditGeneration ?? localEditGeneration
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            guard !syncV2AccountTransitionInProgress,
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
                          !syncV2AccountTransitionInProgress,
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
                          !syncV2AccountTransitionInProgress,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    guard let pending = try await application.pendingAdoption(workID: activeWorkID),
                          pending.workID == activeWorkID,
                          pending.inboxID == inboxID,
                          !syncV2AccountTransitionInProgress,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    applySnapshotSyncV2State(projected)

                    let session = await application.beginSession(workID: pending.workID)
                    guard !syncV2AccountTransitionInProgress,
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
                    guard !syncV2AccountTransitionInProgress,
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
                    guard !syncV2AccountTransitionInProgress,
                          opened.workID == activeWorkID,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    guard let value = opened.document else { return }
                    guard !syncV2AccountTransitionInProgress,
                          currentDocumentSessionToken == expectedSession,
                          localEditGeneration == expectedEditGeneration,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          installSnapshotSyncV2Opened(opened, value: value) else { return }
                    let adoptedState = await application.uiState(workID: opened.workID)
                    guard !syncV2AccountTransitionInProgress,
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

    @discardableResult
    func openSnapshotSyncV2(workID: UUID) async -> Bool {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application else { return false }
        cancelSnapshotSyncV2BackgroundOperations()
        let targetWorkID = WorkID(workID)
        let expectedAccountScope = snapshotSyncV2AccountScope
        let didOpen = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            var didOpen = false
            let transitioned = await performDocumentTransition {
                do {
                    // `performDocumentTransition` first confirms IME input and
                    // flushes a dirty editor through the local SQLite
                    // checkpoint.  It never wakes or awaits the remote worker.
                    let opened = try await application.openLocal(workID: targetWorkID)
                    guard !syncV2AccountTransitionInProgress,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          opened.workID == targetWorkID,
                          let value = opened.document else { return }
                    guard installSnapshotSyncV2Opened(opened, value: value) else { return }
                    let state = await application.uiState(workID: opened.workID)
                    guard !syncV2AccountTransitionInProgress,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2ActiveWorkID == targetWorkID else { return }
                    applySnapshotSyncV2State(state)
                    didOpen = true
                } catch {
                    operationErrorMessage = "作品を安全に開けませんでした。"
                }
            }
            return transitioned && didOpen
        }
        guard didOpen else { return false }
        scheduleAutomaticAdoptionAfterCleanOpen(
            application,
            workID: targetWorkID
        )
        return true
    }

    /// Opens a remote-only catalog row without making the current editor wait
    /// for HTTP. Download/verification is performed in the application layer;
    /// only the final, session-checked install crosses the document gate.
    /// Returning true means the request was accepted, not that remote bytes
    /// have already become the active editor.
    @discardableResult
    func startRemoteOnlySnapshotSyncV2Open(workID: WorkID) async -> Bool {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application,
              syncV2LibraryItems.contains(where: {
                  $0.workID == workID && $0.availability == .remoteOnly
              }),
              snapshotSyncV2RemoteOnlyOpenTask == nil else { return false }
        let expectedSession = currentDocumentSessionToken
        let expectedAccountScope = snapshotSyncV2AccountScope
        let operationToken = UUID()
        snapshotSyncV2RemoteOnlyOpenToken = operationToken
        snapshotSyncV2RemoteOnlyOpenTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   snapshotSyncV2RemoteOnlyOpenToken == operationToken {
                    snapshotSyncV2RemoteOnlyOpenToken = nil
                    snapshotSyncV2RemoteOnlyOpenTask = nil
                }
            }
            do {
                let opened = try await application.open(workID: workID)
                let matchesRequestedWork = acceptsSnapshotSyncV2RemoteOnlyOpen(
                    opened,
                    requestedWorkID: workID
                )
                guard matchesRequestedWork,
                      !Task.isCancelled,
                      let self,
                      !syncV2AccountTransitionInProgress,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      snapshotSyncV2AccountScope == expectedAccountScope else { return }
                _ = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          !syncV2AccountTransitionInProgress,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2LibraryItems.contains(where: { $0.workID == workID }) else {
                        return false
                    }
                    var installed = false
                    let transitioned = await performDocumentTransition {
                        guard snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                              !syncV2AccountTransitionInProgress,
                              currentDocumentSessionToken == expectedSession,
                              snapshotSyncV2AccountScope == expectedAccountScope,
                              acceptsSnapshotSyncV2RemoteOnlyOpen(
                                  opened,
                                  requestedWorkID: workID
                              ),
                              let value = opened.document else {
                            throw SyncV2ApplicationError.workNotFound
                        }
                        guard installSnapshotSyncV2Opened(opened, value: value) else {
                            throw SyncV2ApplicationError.invalidRuntimeMode
                        }
                        let state = await application.uiState(workID: opened.workID)
                        guard snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                              !syncV2AccountTransitionInProgress,
                              snapshotSyncV2AccountScope == expectedAccountScope,
                              syncV2ActiveWorkID == workID else { return }
                        applySnapshotSyncV2State(state)
                        snapshotSyncV2RemoteOnlyReadyWorkID = opened.workID
                        installed = true
                    }
                    return transitioned && installed
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !syncV2AccountTransitionInProgress,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      currentDocumentSessionToken == expectedSession,
                      snapshotSyncV2AccountScope == expectedAccountScope else { return }
                operationErrorMessage = "作品を取得できませんでした。接続が戻ると再試行できます。"
            }
        }
        return true
    }

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

    @discardableResult
    func installSnapshotSyncV2Opened(
        _ opened: SyncV2OpenedWork,
        value: NovelDocument
    ) -> Bool {
        guard opened.document == value,
              opened.documentCreatedAt.timeIntervalSince1970.isFinite,
              validateV2AttachmentRecords(opened.attachments),
              let portableMirror = try? SyncV2PortableMetadata.splitLocalMirrorResources(
                  opened.resources
              ) else {
            operationErrorMessage = "portable metadataが壊れているため、作品を開けませんでした。"
            snapshotSyncOutcome = .failed
            return false
        }
        document = value
        syncV2ActiveWorkID = opened.workID
        documentCreatedAt = opened.documentCreatedAt
        // v2 does not derive identity from a path or create a WorkID folder.
        // Keep this URL only as the import/export compatibility boundary.
        documentURL = libraryRoot.standardizedFileURL
        replaceAttachments(opened.attachments.map {
            Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
        })
        syncV2AttachmentPayloads = Dictionary(
            uniqueKeysWithValues: opened.attachments.map { ($0.fileName, $0.bytes) }
        )
        syncV2AttachmentIDs = Dictionary(
            uniqueKeysWithValues: opened.attachments.map { ($0.fileName, $0.attachmentId) }
        )
        syncV2PortableCreatedAt = portableMirror.portableCreatedAt
        syncV2PortableResources = portableMirror.resources
        userDefaults.set(opened.workID.rawValue.uuidString, forKey: Self.lastWorkIDKey)
        syncV2KeepBothPendingWorkID = nil
        selectedChapterID = value.chapters.first?.id
        selectedEpisodeID = value.chapters.first?.episodes.first?.id
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        startupState = .ready
        saveState = .saved
        applySnapshotSyncV2State(snapshotSyncState)
        return true
    }

    func applySnapshotSyncV2State(_ state: SyncUIState?) {
        snapshotSyncState = state
        snapshotSyncConflict = state?.conflict
        guard let state else { return }
        switch state.remoteProgress {
        case .idle, .noChanges:
            snapshotSyncOutcome = .idle
        case .pending:
            snapshotSyncOutcome = .pending
        case .syncing:
            snapshotSyncOutcome = .syncing
        case .needsChoice, .readyForSafeAdoption:
            snapshotSyncOutcome = .conflict
        case .offline, .authenticationRequired, .parkedDifferentAccount,
             .fenceChanged, .quarantined, .retryable:
            snapshotSyncOutcome = .offline
        case .failed, .receiptMismatch:
            snapshotSyncOutcome = .failed
        }
    }

    private func automaticAdoptionExpectation(
        for workID: WorkID,
        validatingEditorSurface: Bool
    ) -> AutoAdoptionExpectation? {
        guard !syncV2AccountTransitionInProgress,
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
              !syncV2AccountTransitionInProgress,
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

    private func scheduleAutomaticAdoptionAfterCleanOpen(
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

    private func startSnapshotSyncV2Reprojection(
        _ application: SyncV2Application,
        workID: WorkID?,
        automaticAdoption: AutoAdoptionExpectation?,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        resumesWorker: Bool
    ) {
        guard !syncV2AccountTransitionInProgress,
              snapshotSyncV2AccountScope == expectedAccountScope else { return }
        snapshotSyncV2ReprojectionToken = nil
        snapshotSyncV2ReprojectionTask?.cancel()
        let operationToken = UUID()
        snapshotSyncV2ReprojectionToken = operationToken
        snapshotSyncV2ReprojectionTask = Task { @MainActor [weak self] in
            defer {
                if let self, snapshotSyncV2ReprojectionToken == operationToken {
                    snapshotSyncV2ReprojectionToken = nil
                    snapshotSyncV2ReprojectionTask = nil
                }
            }
            if resumesWorker {
                try? await application.resumePending()
            }
            guard let self,
                  !syncV2AccountTransitionInProgress,
                  snapshotSyncV2ReprojectionToken == operationToken,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return }
            if let workID {
                guard syncV2ActiveWorkID == workID else { return }
                await reprojectAfterResume(
                    application,
                    workID: workID,
                    automaticAdoption: automaticAdoption,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
            } else {
                await refreshSnapshotSyncV2Projection(
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
            }
        }
    }

    private func reprojectAfterResume(
        _ application: SyncV2Application,
        workID: WorkID,
        automaticAdoption: AutoAdoptionExpectation?,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        operationToken: UUID
    ) async {
        for _ in 0 ..< 600 {
            guard !Task.isCancelled,
                  !syncV2AccountTransitionInProgress,
                  snapshotSyncV2ReprojectionToken == operationToken,
                  snapshotSyncV2AccountScope == expectedAccountScope,
                  syncV2ActiveWorkID == workID else { return }
            guard let state = await application.uiState(workID: workID) else {
                await refreshSnapshotSyncV2Projection(
                    workID: workID,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
                return
            }
            guard snapshotSyncV2ReprojectionToken == operationToken,
                  !syncV2AccountTransitionInProgress,
                  snapshotSyncV2AccountScope == expectedAccountScope,
                  syncV2ActiveWorkID == workID else { return }
            applySnapshotSyncV2State(state)
            switch state.remoteProgress {
            case .pending, .syncing:
                try? await Task.sleep(nanoseconds: 50_000_000)
            case .readyForSafeAdoption:
                if let automaticAdoption,
                   await adoptPendingSnapshotSyncV2(
                       expectedSession: automaticAdoption.session,
                       expectedEditGeneration: automaticAdoption.editGeneration,
                       expectedAccountScope: automaticAdoption.accountScope
                   ) {
                    return
                }
                await refreshSnapshotSyncV2Projection(
                    workID: workID,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
                return
            default:
                await refreshSnapshotSyncV2Projection(
                    workID: workID,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
                return
            }
        }
        await refreshSnapshotSyncV2Projection(
            workID: workID,
            expectedAccountScope: expectedAccountScope,
            operationToken: operationToken
        )
    }

    func refreshSnapshotSyncV2Projection(
        workID: WorkID? = nil,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope? = nil,
        operationToken: UUID? = nil
    ) async {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application else { return }
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        libraryRefreshGeneration &+= 1
        let refreshGeneration = libraryRefreshGeneration
        // Taking library projection ownership also retires an older catalog
        // request. Its generation-mismatched defer cannot clear this latch.
        syncV2RemoteCatalogIsLoading = false
        if let workID, let state = await application.uiState(workID: workID) {
            guard !syncV2AccountTransitionInProgress,
                  libraryRefreshGeneration == refreshGeneration,
                  snapshotSyncV2AccountScope == expectedAccountScope,
                  operationToken == nil || snapshotSyncV2ReprojectionToken == operationToken else {
                return
            }
            if syncV2ActiveWorkID == workID {
                applySnapshotSyncV2State(state)
            }
        }
        guard let projection = try? await application.library() else { return }
        guard !syncV2AccountTransitionInProgress,
              libraryRefreshGeneration == refreshGeneration,
              snapshotSyncV2AccountScope == expectedAccountScope,
              operationToken == nil || snapshotSyncV2ReprojectionToken == operationToken else {
            return
        }
        _ = applySnapshotSyncV2LibraryProjection(
            projection,
            expectedAccountScope: expectedAccountScope,
            refreshGeneration: refreshGeneration
        )
    }
}
