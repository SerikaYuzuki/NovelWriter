import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

extension AppState {
    /// Snapshot and portable manifests use canonical UTC whole-second anchors.
    /// Keep the value normalized at the app boundary so package fractions or
    /// a fresh `Date()` cannot make a reopened WorkID look like a new anchor.
    static func normalizedSnapshotSyncV2Date(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

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
        reason: SyncV2CheckpointReason = .autosave,
        resources: [PortableResource]? = nil
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
            let documentCreatedAt = Self.normalizedSnapshotSyncV2Date(
                snapshotSyncV2DocumentCreatedAt ?? Date()
            )
            snapshotSyncV2DocumentCreatedAt = documentCreatedAt
            if snapshotSyncV2Session?.workID != workID {
                snapshotSyncV2Session = await application.beginSession(workID: workID)
            }
            _ = try await application.checkpoint(
                workID: workID,
                document: document,
                reason: reason,
                documentCreatedAt: documentCreatedAt,
                attachments: snapshotSyncV2Attachments,
                resources: resources
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
                        attachments: opened.attachments,
                        resources: opened.resources
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
                    createdAt: imported.documentCreatedAt,
                    attachments: imported.attachments,
                    resources: imported.resources
                )
                let saved = await checkpointSnapshotSyncV2(
                    imported.document,
                    reason: .migration,
                    resources: imported.resources
                )
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
        attachments: [SyncAttachment] = [],
        resources: [PortableResource] = []
    ) {
        snapshotSyncAutoAdoptionTask?.cancel()
        snapshotSyncAutoAdoptionTask = nil
        self.document = document
        snapshotSyncV2Attachments = attachments
        snapshotSyncV2Resources = resources
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
        snapshotSyncV2DocumentCreatedAt = Self.normalizedSnapshotSyncV2Date(createdAt)
        userDefaults.set(workID.rawValue.uuidString, forKey: "fuminiwa.v2.activeWorkID")
        snapshotSyncV2Session = nil
        saveState = .saved
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
                    attachments: opened.attachments,
                    resources: opened.resources
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
}
