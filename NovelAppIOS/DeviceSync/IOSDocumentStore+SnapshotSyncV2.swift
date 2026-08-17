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

extension IOSDocumentStore {
    /// Retires asynchronous remote-only work before a new document operation
    /// can change the session. The task itself must not clear a newer task's
    /// owner slot from its defer block.
    func cancelSnapshotSyncV2BackgroundOperations() {
        snapshotSyncV2RemoteOnlyOpenToken = nil
        snapshotSyncV2RemoteOnlyOpenTask?.cancel()
        snapshotSyncV2RemoteOnlyOpenTask = nil
        snapshotSyncV2RemoteOnlyReadyWorkID = nil
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
                let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
                // Test composition is selected only by an explicitly injected
                // library root. Never inspect XCTest or process environment
                // here: the production app must not be able to redirect its
                // SQLite/transport authority to a temporary test runtime.
                if let injectedTestRoot {
                    let key = injectedTestRoot
                    if let cached = Self.testRuntimeApplications[key] {
                        snapshotSyncV2Application = cached
                    } else {
                        let configuration: TestRuntimeConfiguration
                        if let cachedConfiguration = Self.testRuntimeConfigurations[key] {
                            configuration = cachedConfiguration
                        } else {
                            let newConfiguration = try TestRuntimeConfiguration()
                            Self.testRuntimeConfigurations[key] = newConfiguration
                            configuration = newConfiguration
                        }
                        let application = try await SnapshotSyncV2Runtime.makeApplication(
                            mode: .test(configuration)
                        )
                        Self.testRuntimeApplications[key] = application
                        snapshotSyncV2Application = application
                    }
                } else if let configuration = try? ProductionRuntimeConfiguration(
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
            } catch {
                snapshotSyncV2Application = nil
            }
        }
        snapshotSyncV2ConfigurationTask = task
        await task.value
        return snapshotSyncV2Application != nil
    }

    private func makeProductionAuthVault() -> (any AuthSessionVault)? {
        #if canImport(Security)
        KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync.ios")
        #else
        nil
        #endif
    }

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
        guard let application = snapshotSyncV2Application else { return }
        // resumePending only wakes the durable worker.  Keep lifecycle/UI
        // non-blocking, then observe the actor's projected terminal state so
        // conflict/adoption/status changes become visible after the worker.
        Task { @MainActor [weak self] in
            try? await application.resumePending()
            if let workID = self?.syncV2ActiveWorkID {
                await self?.reprojectAfterResume(application, workID: workID)
            } else {
                await self?.refreshSnapshotSyncV2Projection()
            }
        }
    }

    @discardableResult
    func synchronizeSnapshotSyncV2() async -> Bool {
        guard let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let result = try await application.synchronize(workID: workID)
            applySnapshotSyncV2State(result.state)
            return true
        } catch {
            snapshotSyncOutcome = .offline
            return false
        }
    }

    /// Adopt a verified remote resolution only after the iOS document gate,
    /// IME boundary, editor generation, and local pending intent are safe.
    @discardableResult
    func adoptPendingSnapshotSyncV2(
        expectedSession: IOSDocumentSessionToken? = nil,
        expectedEditGeneration: UInt64? = nil
    ) async -> Bool {
        guard let application = snapshotSyncV2Application,
              startupState == .ready,
              let activeWorkID = syncV2ActiveWorkID else { return false }
        let expectedSession = expectedSession ?? currentDocumentSessionToken
        let expectedEditGeneration = expectedEditGeneration ?? localEditGeneration
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDocumentSessionToken == expectedSession,
                  localEditGeneration == expectedEditGeneration,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }

            // Adoption is a safe boundary, not a hidden save trigger.  A
            // dirty editor must finish its local checkpoint before the user
            // explicitly retries adoption; saveNow here used to create a new
            // intent and race the server-adopted source version.
            guard saveState == .saved,
                  currentDocumentSessionToken == expectedSession,
                  localEditGeneration == expectedEditGeneration else {
                operationErrorMessage = "未保存の変更があります。端末へ適用する前に保存してください。"
                return false
            }
            switch editorCommandSession.captureActiveCommittedText() {
            case .compositionInProgress:
                operationErrorMessage = "日本語入力を確定してから、端末へ適用してください。"
                return false
            case let .captured(text):
                guard let episodeID = selectedEpisodeID,
                      document.episode(episodeID)?.episode.content == text else {
                    operationErrorMessage = "本文が更新されたため、端末への適用を延期しました。"
                    return false
                }
            case .notActive:
                break
            }
            do {
                // The worker already projected the receipt into the durable
                // application state.  Reading uiState/pendingAdoption is
                // local; adoption never performs a second network round trip.
                guard let projected = await application.uiState(workID: activeWorkID),
                      projected.lastTypedResult == .adoptionPending,
                      case let .readyForSafeAdoption(inboxID) = projected.remoteProgress,
                      let pending = try await application.pendingAdoption(workID: activeWorkID),
                      pending.inboxID == inboxID else { return false }
                applySnapshotSyncV2State(projected)

                let session = await application.beginSession(workID: pending.workID)
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
                let token = try await application.documentGateToken(for: session)
                let boundary = SafeAdoptionBoundary(
                    workID: pending.workID,
                    inboxID: pending.inboxID,
                    session: session,
                    gate: token
                )
                let opened = try await application.applyStagedRemote(at: boundary)
                guard let value = opened.document else { return false }
                guard installSnapshotSyncV2Opened(opened, value: value) else { return false }
                await applySnapshotSyncV2State(application.uiState(workID: opened.workID))
                return true
            } catch {
                snapshotSyncOutcome = .failed
                return false
            }
        }
    }

    @discardableResult
    func openSnapshotSyncV2(workID: UUID) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        cancelSnapshotSyncV2BackgroundOperations()
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            var didOpen = false
            let transitioned = await performDocumentTransition {
                do {
                    // `performDocumentTransition` first confirms IME input and
                    // flushes a dirty editor through the local SQLite
                    // checkpoint.  It never wakes or awaits the remote worker.
                    let opened = try await application.openLocal(workID: WorkID(workID))
                    guard let value = opened.document else { return }
                    guard installSnapshotSyncV2Opened(opened, value: value) else { return }
                    await applySnapshotSyncV2State(application.uiState(workID: opened.workID))
                    didOpen = true
                } catch {
                    operationErrorMessage = "作品を安全に開けませんでした。"
                }
            }
            return transitioned && didOpen
        }
    }

    /// Opens a remote-only catalog row without making the current editor wait
    /// for HTTP. Download/verification is performed in the application layer;
    /// only the final, session-checked install crosses the document gate.
    /// Returning true means the request was accepted, not that remote bytes
    /// have already become the active editor.
    @discardableResult
    func startRemoteOnlySnapshotSyncV2Open(workID: WorkID) async -> Bool {
        guard let application = snapshotSyncV2Application,
              syncV2LibraryItems.contains(where: { $0.workID == workID }),
              snapshotSyncV2RemoteOnlyOpenTask == nil else { return false }
        let expectedSession = currentDocumentSessionToken
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
                guard !Task.isCancelled,
                      let self,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken else { return }
                _ = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          currentDocumentSessionToken == expectedSession,
                          syncV2LibraryItems.contains(where: { $0.workID == workID }) else {
                        return false
                    }
                    var installed = false
                    let transitioned = await performDocumentTransition {
                        guard snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                              currentDocumentSessionToken == expectedSession,
                              let value = opened.document else {
                            throw SyncV2ApplicationError.workNotFound
                        }
                        guard installSnapshotSyncV2Opened(opened, value: value) else {
                            throw SyncV2ApplicationError.invalidRuntimeMode
                        }
                        let state = await application.uiState(workID: opened.workID)
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
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      currentDocumentSessionToken == expectedSession else { return }
                operationErrorMessage = "作品を取得できませんでした。接続が戻ると再試行できます。"
            }
        }
        return true
    }

    @discardableResult
    func restoreSnapshotSyncV2(snapshotID raw: String) async -> Bool {
        guard let app = snapshotSyncV2Application,
              let activeWorkID = syncV2ActiveWorkID,
              let snapshotID = try? SnapshotID(rawValue: raw) else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            guard saveState == .saved else {
                operationErrorMessage = "未保存の変更があります。復元前に保存してください。"
                return false
            }
            do {
                let result = try await app.restore(
                    workID: activeWorkID, snapshotID: snapshotID
                )
                applySnapshotSyncV2State(result.state)
                let opened = try await app.openLocal(workID: activeWorkID)
                guard let value = opened.document else { return false }
                guard installSnapshotSyncV2Opened(opened, value: value) else { return false }
                await refreshSnapshotSyncV2Projection(workID: activeWorkID)
                return true
            } catch {
                snapshotSyncOutcome = .failed
                return false
            }
        }
    }

    @discardableResult
    func resolveSnapshotSyncV2Conflict(
        using choice: SyncV2ConflictChoice,
        expectedSelection: IOSSnapshotSyncV2ConflictSelection
    ) async -> Bool {
        guard let app = snapshotSyncV2Application,
              startupState == .ready,
              let activeWorkID = syncV2ActiveWorkID,
              let expectedSession = currentDocumentSessionToken else { return false }
        let expectedEditGeneration = localEditGeneration
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDocumentSessionToken == expectedSession,
                  localEditGeneration == expectedEditGeneration,
                  selectionMatchesCurrentConflict(expectedSelection),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }

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
                let result = try await app.resolveConflict(workID: workID, action: action)
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
                          localEditGeneration == expectedEditGeneration else {
                        operationErrorMessage = "両方を保持する作品を安全に開けませんでした。"
                        return false
                    }
                    guard installSnapshotSyncV2Opened(opened, value: value) else {
                        return false
                    }
                    await applySnapshotSyncV2State(app.uiState(workID: opened.workID))
                } else {
                    applySnapshotSyncV2State(result.state)
                }
                // Resolution is queued locally.  The worker will perform the
                // network operation outside this UI call; reproject its
                // eventual conflict/adoption result without making this
                // action wait.
                Task { @MainActor [weak self] in
                    switch choice {
                    case .useServer:
                        try? await app.resumePending()
                        await self?.reprojectAfterResume(
                            app,
                            workID: workID,
                            automaticAdoption: AutoAdoptionExpectation(
                                session: expectedSession,
                                editGeneration: expectedEditGeneration
                            )
                        )
                    case .useDevice:
                        try? await app.resumePending()
                        await self?.reprojectAfterResume(app, workID: workID)
                    case .keepBoth:
                        try? await app.resumePending()
                        await self?.reprojectAfterResume(app, workID: workID)
                    }
                }
                return true
            } catch {
                if choice == .keepBoth {
                    syncV2KeepBothPendingWorkID = nil
                }
                snapshotSyncOutcome = .failed
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

    private func reprojectAfterResume(
        _ application: SyncV2Application,
        workID: WorkID,
        automaticAdoption: AutoAdoptionExpectation? = nil
    ) async {
        for _ in 0 ..< 600 {
            guard !Task.isCancelled else { return }
            guard let state = await application.uiState(workID: workID) else {
                await refreshSnapshotSyncV2Projection(workID: workID)
                return
            }
            applySnapshotSyncV2State(state)
            switch state.remoteProgress {
            case .pending, .syncing:
                try? await Task.sleep(nanoseconds: 50_000_000)
            case .readyForSafeAdoption:
                if let automaticAdoption,
                   await adoptPendingSnapshotSyncV2(
                       expectedSession: automaticAdoption.session,
                       expectedEditGeneration: automaticAdoption.editGeneration
                   ) {
                    return
                }
                await refreshSnapshotSyncV2Projection(workID: workID)
                return
            default:
                await refreshSnapshotSyncV2Projection(workID: workID)
                return
            }
        }
        await refreshSnapshotSyncV2Projection(workID: workID)
    }

    func refreshSnapshotSyncV2Projection(workID: WorkID? = nil) async {
        guard let application = snapshotSyncV2Application else { return }
        if let workID, let state = await application.uiState(workID: workID) {
            applySnapshotSyncV2State(state)
        }
        guard let projection = try? await application.library() else { return }
        let localItems = exposesAccountScopedSyncV2Items
            ? projection.items
            : projection.items.filter { $0.accountState == .unbound }
        syncV2LibraryItems = mergeRemoteCatalog(
            into: localItems,
            catalog: exposesAccountScopedSyncV2Items ? syncV2RemoteCatalogItems : []
        )
    }
}
