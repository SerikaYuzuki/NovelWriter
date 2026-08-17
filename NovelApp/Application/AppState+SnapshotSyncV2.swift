import AppKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

extension AppState {
    /// The live editor identity is an explicitly allocated WorkID. A ready
    /// session must have this value; the document payload is never its key.
    var currentSnapshotSyncV2WorkID: WorkID? {
        snapshotSyncV2ActiveWorkID ?? snapshotSyncV2Session?.workID
    }

    func configureSnapshotSyncV2(
        using factory: (@Sendable () async throws -> SyncV2Application)?
    ) async -> Bool {
        guard let factory else {
            snapshotSyncV2Application = nil
            startupState = .recovery(.init(message: "端末の保存領域を初期化できませんでした。"))
            return false
        }
        do {
            snapshotSyncV2Application = try await factory()
            await refreshSnapshotSyncV2UIState()
            return true
        } catch {
            snapshotSyncV2Application = nil
            startupState = .recovery(.init(message: "端末の保存領域を初期化できませんでした。"))
            return false
        }
    }

    /// The ordinary save boundary.  It awaits the local SQLite checkpoint only;
    /// the shared application schedules any remote work after that transaction.
    @discardableResult
    func checkpointSnapshotSyncV2(
        _ document: NovelDocument,
        reason: SyncV2CheckpointReason = .autosave
    ) async -> Bool {
        guard let application = snapshotSyncV2Application else {
            saveState = .failed
            return false
        }
        do {
            let workID: WorkID
            if let currentSnapshotSyncV2WorkID {
                workID = currentSnapshotSyncV2WorkID
            } else if !startupState.isReady {
                // A pre-bootstrap checkpoint is a new local work. Allocate
                // its WorkID explicitly; the document payload is not the
                // session identity even during this first assignment.
                workID = WorkID(UUID())
            } else {
                saveState = .failed
                return false
            }
            snapshotSyncV2ActiveWorkID = workID
            if snapshotSyncV2Session?.workID != workID {
                snapshotSyncV2Session = await application.beginSession(workID: workID)
                snapshotSyncV2DocumentCreatedAt = snapshotSyncV2DocumentCreatedAt ?? Date()
            }
            _ = try await application.checkpoint(
                workID: workID,
                document: document,
                reason: reason,
                documentCreatedAt: snapshotSyncV2DocumentCreatedAt ?? Date(),
                attachments: snapshotSyncV2Attachments
            )
            saveState = .saved
            await refreshSnapshotSyncV2UIState()
            return true
        } catch {
            saveState = .failed
            return false
        }
    }

    func markDocumentDirty() {
        saveState = .unsaved
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    @discardableResult
    func saveNow() async -> Bool {
        await saveCoordinator.saveNow()
    }

    func saveBeforeTermination() async -> Bool {
        guard terminationTask == nil else {
            return await terminationTask?.value ?? false
        }
        isTerminationPending = true
        let task: Task<Bool, Never> = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await documentOperationGate.perform { [weak self] in
                guard let self,
                      editorCommandSession.prepareForDocumentTransition() else { return false }
                defer { editorCommandSession.resumeAfterDocumentTransition() }
                return await saveNow()
            }
        }
        terminationTask = task
        let result = await task.value
        terminationTask = nil
        isTerminationPending = false
        return result
    }

    func handleSaveEvent(_ event: V2DocumentSaveCoordinator.SaveEvent) {
        switch event {
        case .dirty: saveState = .unsaved
        case .saving: saveState = .saving
        case .saved: saveState = .saved
        case .failed: saveState = .failed
        }
    }

    /// Launch/foreground/network recovery only wakes the shared outbox once.
    /// It intentionally does not wait for a remote response.
    func resumeSnapshotSyncV2() async {
        guard let application = snapshotSyncV2Application else { return }
        Task { @MainActor [weak self] in
            try? await application.resumePending()
            // Re-project terminal worker state after the background wake. The
            // caller has already returned and never waits for the network lane.
            await self?.refreshSnapshotSyncV2UIState()
            await self?.refreshSnapshotLibrary()
        }
    }

    /// Explicit toolbar sync first drains the local checkpoint, then wakes the
    /// shared planner in a detached UI task. The toolbar never waits for a
    /// remote receipt; `.noChanges` is still rendered as successful sync.
    func synchronizeSnapshotSyncV2() async {
        guard permitsDocumentInteraction,
              await saveNow(),
              let application = snapshotSyncV2Application else { return }
        guard let workID = currentSnapshotSyncV2WorkID else { return }
        Task { @MainActor [weak self] in
            _ = try? await application.synchronize(workID: workID)
            await self?.refreshSnapshotSyncV2UIState()
            await self?.refreshSnapshotLibrary()
        }
    }

    func refreshSnapshotSyncV2UIState() async {
        guard let application = snapshotSyncV2Application else {
            snapshotSyncV2UIState = nil
            snapshotSyncConflict = nil
            return
        }
        guard let workID = currentSnapshotSyncV2WorkID else {
            snapshotSyncV2UIState = nil
            snapshotSyncConflict = nil
            return
        }
        let state = await application.uiState(workID: workID)
        snapshotSyncV2UIState = state
        snapshotSyncConflict = state?.conflict
    }

    func bootstrap(opening: URL? = nil, localFirst _: Bool = true) async {
        guard snapshotSyncV2Application != nil else {
            if case .recovery = startupState {} else {
                startupState = .recovery(.init(message: "端末の保存領域を初期化できませんでした。"))
            }
            return
        }
        if let running = bootstrapTask {
            await running.value
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                hasCompletedBootstrap = true
                bootstrapTask = nil
            }
            if let opening {
                if await !openExternalDocument(at: opening) {
                    startupState = .recovery(.init(message: "作品を取り込めませんでした。原本は変更していません。"))
                }
                return
            }
            let workID = userDefaults.string(forKey: "fuminiwa.v2.activeWorkID")
                .flatMap(UUID.init(uuidString:))
                .map { WorkID($0) }
            if let workID, let application = snapshotSyncV2Application {
                do {
                    let opened = try await application.open(workID: workID)
                    guard let openedDocument = opened.document else {
                        startupState = .recovery(.init(message: "保存済みの作品を読み込めませんでした。"))
                        return
                    }
                    installV2Document(
                        openedDocument,
                        workID: opened.workID,
                        createdAt: opened.documentCreatedAt,
                        attachments: opened.attachments
                    )
                    snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                    await refreshSnapshotSyncV2UIState()
                } catch {
                    startupState = .recovery(.init(message: "保存済みの作品を読み込めませんでした。"))
                    return
                }
            } else {
                let fresh = NovelDocument.newDocument()
                let freshWorkID = WorkID(UUID())
                installV2Document(fresh, workID: freshWorkID, createdAt: Date())
                guard await checkpointSnapshotSyncV2(fresh, reason: .migration) else {
                    startupState = .recovery(.init(message: "新しい作品を端末へ保存できませんでした。"))
                    return
                }
            }
            startupState = .ready
            // The document is ready after the local open/checkpoint.  Catalog
            // refresh is a separate background read and never delays typing.
            Task { @MainActor [weak self] in
                await self?.refreshSnapshotLibrary()
            }
        }
        bootstrapTask = task
        await task.value
    }

    @discardableResult
    func openExternalDocument(at url: URL) async -> Bool {
        let isBootstrapImport = !hasCompletedBootstrap && startupState == .loading
        guard permitsDocumentChoice || isBootstrapImport else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            do {
                // The portable bridge is the only package boundary. Import
                // chooses a fresh WorkID; the package URL never enters the
                // ordinary session identity.
                let imported = try await portableBridge.importExplicitPackage(from: url)
                let importedWorkID = WorkID(UUID())
                installV2Document(
                    imported.document,
                    workID: importedWorkID,
                    createdAt: Date(),
                    attachments: imported.attachments
                )
                let saved = await checkpointSnapshotSyncV2(imported.document, reason: .migration)
                if saved {
                    startupState = .ready
                    Task { @MainActor [weak self] in
                        await self?.refreshSnapshotLibrary()
                    }
                }
                return saved
            } catch {
                externalDocumentOpenErrorMessage = "作品を取り込めませんでした。"
                return false
            }
        }
    }

    func installV2Document(
        _ document: NovelDocument,
        workID: WorkID,
        createdAt: Date,
        attachments: [SyncAttachment] = []
    ) {
        snapshotSyncAutoAdoptionTask?.cancel()
        snapshotSyncAutoAdoptionTask = nil
        self.document = document
        snapshotSyncV2Attachments = attachments
        attachmentPreviewURLs.removeAll()
        self.attachments = attachments.map {
            Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
        }
        selectedChapterID = document.chapters.first?.id
        selectedEpisodeID = document.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = document.chapters.first.map { .chapter($0.id) } ?? .unassigned
        editorContentGeneration &+= 1
        documentSessionToken = AppDocumentSessionToken(
            generation: editorContentGeneration,
            documentID: document.id,
            workID: workID
        )
        snapshotSyncV2ActiveWorkID = workID
        snapshotSyncV2DocumentCreatedAt = createdAt
        userDefaults.set(workID.rawValue.uuidString, forKey: "fuminiwa.v2.activeWorkID")
        snapshotSyncV2Session = nil
        saveState = .saved
    }

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
            attachments: opened.attachments
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
                  case .captured = activeCommittedTextCapture() else {
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
                let capture = activeCommittedTextCapture()
                guard case .captured = capture else {
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
                    attachments: opened.attachments
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
                    attachments: opened.attachments
                )
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                return false
            }
        }
    }

    func refreshSnapshotLibrary() async {
        guard let application = snapshotSyncV2Application else { return }
        let shouldPresentSelection = !startupState.isReady
        let connection: StartupLibraryConnection = switch authUIState {
        case .signedIn: .available
        case .signedOut, .unavailable, .signingIn, .failed: .offline
        }
        lastStartupLibraryConnection = connection
        guard let projection = try? await application.library() else {
            snapshotSyncLibraryWorks = []
            snapshotSyncCurrentWorkAccountState = nil
            if shouldPresentSelection {
                startupState = .documentSelection(.init(works: [], presentation: .localAndRemote, connection: connection))
            }
            return
        }
        snapshotSyncCurrentWorkAccountState = currentSnapshotSyncV2WorkID.flatMap { workID in
            projection.items.first(where: { $0.workID == workID })?.accountState
        }
        var worksByID = Dictionary(uniqueKeysWithValues: projection.items.compactMap { item -> (WorkID, StartupLibraryWork)? in
            guard item.accountState == .active || item.accountState == .unbound else { return nil }
            let availability: StartupLibraryWorkAvailability = switch item.availability {
            case .localOnly: .local
            case .cached: .cached
            case .remoteOnly: .remoteOnly
            }
            let withConflict = item.conflict != nil || item.remoteProgress == .needsChoice
            let work = StartupLibraryWork(
                id: item.workID.rawValue,
                title: item.title,
                availability: withConflict ? .conflict : availability,
                workID: item.workID,
                remoteProgress: item.remoteProgress
            )
            return (item.workID, work)
        })
        for remote in snapshotSyncRemoteCatalogItems {
            if let local = worksByID[remote.workID] {
                let availability: StartupLibraryWorkAvailability = local.availability == .conflict
                    ? .conflict
                    : .cached
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: local.title.isEmpty ? remote.title : local.title,
                    availability: availability,
                    workID: remote.workID,
                    remoteProgress: local.remoteProgress
                )
            } else {
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: remote.title,
                    availability: .remoteOnly,
                    workID: remote.workID,
                    remoteProgress: .idle
                )
            }
        }
        let works = worksByID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        snapshotSyncLibraryWorks = works
        if shouldPresentSelection {
            startupState = .documentSelection(.init(works: works, presentation: .localAndRemote, connection: connection))
        }
    }

    /// Refresh the account-scoped remote catalog in the background. The
    /// provider performs account/fence filtering; this layer only deduplicates
    /// by WorkID and merges the result into the local shelf.
    func refreshSnapshotRemoteCatalog() async {
        guard let application = snapshotSyncV2Application,
              case .signedIn = authUIState else { return }
        do {
            var cursor: String?
            var items: [SyncV2RemoteCatalogEntry] = []
            repeat {
                let page = try await application.refreshRemoteCatalog(
                    cursor: cursor,
                    pageSize: 100
                )
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
            snapshotSyncRemoteCatalogItems = items.reduce(into: [:]) { result, item in
                result[item.workID] = item
            }.values.sorted {
                $0.workID.description < $1.workID.description
            }
            await refreshSnapshotLibrary()
        } catch {
            // Offline catalog reads leave the verified local shelf intact.
        }
    }

    @discardableResult
    func openLibraryWork(_ work: StartupLibraryWork) async -> Bool {
        guard let application = snapshotSyncV2Application,
              work.isOpenable,
              permitsDocumentChoice else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            do {
                let opened = try await application.open(workID: work.workID)
                guard let openedDocument = opened.document else { return false }
                installV2Document(
                    openedDocument,
                    workID: opened.workID,
                    createdAt: opened.documentCreatedAt,
                    attachments: opened.attachments
                )
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                startupState = .ready
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                return false
            }
        }
    }

    func createNewV2Document() async {
        guard permitsDocumentChoice else { return }
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            let fresh = NovelDocument.newDocument()
            let freshWorkID = WorkID(UUID())
            installV2Document(fresh, workID: freshWorkID, createdAt: Date())
            _ = await checkpointSnapshotSyncV2(fresh, reason: .navigation)
            startupState = .ready
            Task { @MainActor [weak self] in
                await self?.refreshSnapshotLibrary()
            }
        }
    }

    /// Explicitly copies an unbound local work into the signed-in account.
    /// The source WorkID remains untouched; the newly-created WorkID becomes
    /// the editor session so later checkpoints cannot silently rebind the
    /// original unbound work.
    @discardableResult
    func cloneCurrentWorkIntoActiveAccount() async -> Bool {
        guard canCloneCurrentWorkIntoActiveAccount,
              let application = snapshotSyncV2Application,
              let sourceWorkID = currentSnapshotSyncV2WorkID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard await saveNow() else { return false }
            do {
                let result = try await application.cloneWorkIntoActiveAccount(
                    sourceWorkID: sourceWorkID,
                    newWorkID: WorkID(UUID()),
                    newDocumentID: DocumentID(UUID())
                )
                let opened = try await application.open(workID: result.newWorkID)
                guard let cloned = opened.document else { return false }
                installV2Document(
                    cloned,
                    workID: opened.workID,
                    createdAt: opened.documentCreatedAt,
                    attachments: opened.attachments
                )
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                snapshotSyncCurrentWorkAccountState = .active
                startupState = .ready
                await refreshSnapshotSyncV2UIState()
                await refreshSnapshotLibrary()
                return true
            } catch {
                return false
            }
        }
    }

    func presentImportPanel() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = await openExternalDocument(at: url)
    }

    func presentExportPanel() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.nameFieldStringValue = "\(document.title).novelpkg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Export is the only ordinary path allowed to call the package
            // codec. The v2 SQLite checkpoint remains the live authority.
            try await exportDocumentPackage(to: url, expectedSession: documentSessionToken)
            operationMessage = "作品を書き出しました。"
        } catch {
            operationMessage = "作品を書き出せませんでした。"
        }
    }

    func refreshSnapshotHistory() async {
        guard let application = snapshotSyncV2Application else { return }
        guard let workID = currentSnapshotSyncV2WorkID else {
            snapshotSyncHistory = []
            return
        }
        do {
            var cursor: String?
            var items: [SyncV2HistoryItem] = []
            repeat {
                let page = try await application.historyPage(
                    workID: workID,
                    cursor: cursor,
                    pageSize: 100
                )
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
            snapshotSyncHistory = items
        } catch {
            snapshotSyncHistory = []
        }
    }

    func dismissOperationMessage() {
        operationMessage = nil
    }
}
