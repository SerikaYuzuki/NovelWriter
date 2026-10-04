import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelWorkspace
import NovelWritingProgress
import os
import SwiftUI

private let snapshotSyncV2StartupLogger = Logger(
    subsystem: "dev.serikayuzuki.fuminiwa",
    category: "startup"
)

extension AppState {
    /// A document identity change explicitly retires background UI operations.
    /// The eventual installer itself must never cancel the Task that owns it.
    func cancelSnapshotSyncV2BackgroundOperations() {
        syncSessionController.cancelBackgroundOperations(remoteOnly: .releaseImmediately)
    }

    func checkpointSnapshotSyncV2(
        using application: SyncV2Application,
        workID: WorkID,
        document: NovelDocument,
        reason: SyncV2CheckpointReason,
        documentCreatedAt: Date,
        attachments: [SyncAttachment] = [],
        resources: [PortableResource]? = nil
    ) async throws -> SyncV2OperationResult {
        #if FUMINIWA_TEST_COMPOSITION
        if let snapshotSyncV2CheckpointOverride {
            return try await snapshotSyncV2CheckpointOverride(
                application,
                workID,
                document,
                reason,
                documentCreatedAt,
                attachments,
                resources
            )
        }
        #endif
        return try await application.checkpoint(
            workID: workID,
            document: document,
            reason: reason,
            documentCreatedAt: documentCreatedAt,
            attachments: attachments,
            resources: resources
        )
    }

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
            if let writingProgressRoot {
                writingProgress.requestConnection(WritingProgressSQLiteStore(root: writingProgressRoot))
            }
            _ = writingMCPController
            await refreshSnapshotSyncV2UIState()
            return true
        } catch {
            let errorType = String(reflecting: type(of: error))
            snapshotSyncV2StartupLogger.error(
                "Snapshot Sync v2 startup failed (error type: \(errorType, privacy: .public))"
            )
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
        attachments: [SyncAttachment]? = nil,
        resources: [PortableResource]? = nil,
        portableCreatedAt: Date? = nil,
        acknowledgeLocalCommit: Bool = false
    ) async -> Bool {
        writingProgress.requestFlush()
        guard let application = snapshotSyncV2Application else {
            saveState = .failed
            return false
        }
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
        let localResources: [PortableResource]?
        do {
            localResources = if let resources {
                try SyncV2PortableMetadata.resourcesForLocalMirror(
                    resources,
                    portableCreatedAt: portableCreatedAt ?? snapshotSyncV2PortableCreatedAt
                )
            } else {
                nil
            }
        } catch {
            saveState = .failed
            return false
        }
        let checkpointAttachments = attachments ?? snapshotSyncV2Attachments
        let context = CheckpointCoordinator.context(of: self)
        if snapshotSyncV2Session?.workID != workID {
            let session = await application.beginSession(workID: workID)
            guard CheckpointCoordinator.matches(context, host: self),
                  snapshotSyncV2Application === application else { return false }
            snapshotSyncV2Session = session
        }
        switch await workspaceCheckpointCoordinator(application).save(
            host: self, document: document, reason: reason, createdAt: documentCreatedAt,
            attachments: checkpointAttachments, resources: localResources,
            isCurrent: { self.snapshotSyncV2Application === application },
            applyCommitted: { result in
                self.applySnapshotSyncV2State(result.state)
                self.applyCheckpointSaveState(result.state)
            },
            applyFailure: { self.saveState = .failed }
        ) {
        case .committed:
            return true
        case .failed:
            return false
        case let .stale(committedLocally):
            // The revision coordinator records durability even when its old UI
            // completion is rejected. Public document operations still fail CAS.
            return acknowledgeLocalCommit && committedLocally
        }
    }

    func markDocumentDirty() {
        saveState = .unsaved
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    @discardableResult
    func saveNow() async -> Bool {
        writingProgress.requestFlush()
        let workID = snapshotSyncV2ActiveWorkID
        let context = CheckpointCoordinator.context(of: self)
        guard await saveCoordinator.saveNow(), CheckpointCoordinator.matches(context, host: self) else { return false }
        do {
            if let workID, let application = snapshotSyncV2Application {
                try await application.promoteCheckpoint(workID: workID)
            }
            return CheckpointCoordinator.matches(context, host: self)
        } catch {
            guard CheckpointCoordinator.matches(context, host: self) else { return false }
            saveState = .failed
            return false
        }
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
                let saved = await saveNow()
                await writingProgress.flush()
                return saved
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
        case .dirty:
            documentChangeRevision &+= 1
            if !editorProgressAlreadyTracked, let workID = currentSnapshotSyncV2WorkID {
                writingProgress.synchronize(document, workID: workID.rawValue)
            }
            saveState = .unsaved
        case .saving: saveState = .saving
        case .saved: saveState = .saved
        case .failed: saveState = .failed
        }
    }

    /// Launch/foreground/network recovery only wakes the shared outbox once.
    /// It intentionally does not wait for a remote response.
    func resumeSnapshotSyncV2(reason: SyncV2WakeReason = .foreground) async {
        guard let application = snapshotSyncV2Application else { return }
        let coordinator = authSessionCoordinator
        let context = CheckpointCoordinator.context(of: self)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await workspaceCheckpointCoordinator(application).resume(
                host: self, reason: reason,
                isCurrent: {
                    self.snapshotSyncV2Application === application && CheckpointCoordinator.matches(context, host: self)
                },
                beforeWake: {
                    if let coordinator {
                        // Pending revoke stays behind the auth gate, outside local saving.
                        try? await self.authOperationGate.perform {
                            try await coordinator.resumePendingRevoke()
                        }
                    }
                },
                afterWake: {
                    await self.refreshSnapshotSyncV2UIState()
                    await self.refreshSnapshotLibrary()
                }
            )
        }
    }

    /// Saving remains available while an authentication operation holds the
    /// transition gate. Only the optional remote request is deferred then.
    func saveAndSyncCurrentWork() async {
        guard permitsDocumentInteraction else { return }
        if canExplicitlySyncCurrentWork {
            await synchronizeSnapshotSyncV2()
        } else {
            let session = documentSessionToken
            let captured = editorCommandSession.captureActiveCommittedText()
            if await saveNow(), documentSessionToken == session,
               case .captured = captured,
               editorCommandSession.captureActiveCommittedText() == captured {
                editorCommandSession.clearProofreadingHighlights()
            }
        }
    }

    /// Explicit sync commits editor input locally before requesting the durable
    /// worker. Remote receipts are projected asynchronously after the gate ends.
    func synchronizeSnapshotSyncV2() async {
        guard canExplicitlySyncCurrentWork,
              let application = snapshotSyncV2Application,
              currentSnapshotSyncV2WorkID != nil else { return }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        _ = await workspaceCheckpointCoordinator(application).explicitlySync(
            host: self,
            permitsRemoteCompletion: { self.snapshotSyncV2Application === application },
            saveLocally: { context in
                await self.documentOperationGate.perform {
                    guard CheckpointCoordinator.matches(context, host: self),
                          self.editorCommandSession.prepareForDocumentTransition() else { return false }
                    defer { self.editorCommandSession.resumeAfterDocumentTransition() }
                    return await self.saveNow()
                }
            },
            didSave: { self.editorCommandSession.clearProofreadingHighlights() },
            requestsRemote: { self.isSignedInToFuminiwa && self.snapshotSyncCurrentWorkAccountState == .active },
            didQueue: { _, _ in
                await self.refreshSnapshotSyncV2UIState()
                await self.refreshSnapshotLibrary()
                return true
            },
            localOnly: {
                await self.refreshSnapshotSyncV2UIState()
                await self.refreshSnapshotLibrary()
            },
            failed: {
                self.operationMessage = "同期を開始できませんでした。原稿はこの端末に保存されています。"
                await self.refreshSnapshotSyncV2UIState()
                await self.refreshSnapshotLibrary()
            }
        )
    }

    func refreshSnapshotSyncV2UIState() async {
        guard let application = snapshotSyncV2Application else {
            applySnapshotSyncV2State(nil)
            return
        }
        await workspaceCheckpointCoordinator(application).project(
            host: self, isCurrent: { self.snapshotSyncV2Application === application },
            apply: { self.applySnapshotSyncV2State($0) }
        )
    }

    private func loadStartupSnapshotLibrary() async {
        await refreshSnapshotLibrary()
        startupState = .documentSelection(.init(
            works: snapshotSyncLibraryWorks,
            presentation: .localAndRemote,
            connection: lastStartupLibraryConnection
        ))
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
            if userDefaults.bool(forKey: "fuminiwa.v2.startInLibrary") {
                await loadStartupSnapshotLibrary()
                return
            }
            let workID = userDefaults.string(forKey: "fuminiwa.v2.activeWorkID")
                .flatMap(UUID.init(uuidString:))
                .map { WorkID($0) }
            var shouldCreateFreshWork = true
            if let workID, let application = snapshotSyncV2Application {
                do {
                    guard try await openBootstrapSnapshotWork(workID, application: application) else { return }
                    shouldCreateFreshWork = false
                } catch SyncV2ApplicationError.workDeletionPending {
                    userDefaults.removeObject(forKey: "fuminiwa.v2.activeWorkID")
                    userDefaults.set(true, forKey: "fuminiwa.v2.startInLibrary")
                    await loadStartupSnapshotLibrary()
                    return
                } catch SyncV2ApplicationError.workNotFound {
                    // A fresh database may follow quarantine of an old v2
                    // schema. The persisted preference then points to a
                    // WorkID that no longer exists in the new local store.
                    userDefaults.removeObject(forKey: "fuminiwa.v2.activeWorkID")
                } catch {
                    startupState = .recovery(.init(message: "保存済みの作品を読み込めませんでした。"))
                    return
                }
            }
            if shouldCreateFreshWork {
                let fresh = NovelDocument.newDocument()
                let freshWorkID = WorkID(UUID())
                guard installV2Document(
                    fresh,
                    workID: freshWorkID,
                    createdAt: Date(),
                    expectedWorkID: freshWorkID,
                    expectedDocumentID: fresh.id
                ) else {
                    startupState = .recovery(.init(message: "新しい作品を検証できませんでした。"))
                    return
                }
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
        guard let application = snapshotSyncV2Application,
              permitsDocumentImport || isBootstrapImport else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentImport || isBootstrapImport,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            cancelSnapshotSyncV2BackgroundOperations()
            let expectedDocumentSession = documentSessionToken
            let expectedWorkID = currentSnapshotSyncV2WorkID
            let expectedSnapshotSession = snapshotSyncV2Session
            if expectedWorkID != nil, saveState != .saved {
                guard await saveNow() else { return false }
            }
            do {
                // The portable bridge is the only package boundary. Import
                // chooses a fresh WorkID; the package URL never enters the
                // ordinary session identity.
                let imported = try await portableBridge.importExplicitPackage(from: url)
                let importedWorkID = WorkID(UUID())
                guard documentSessionToken == expectedDocumentSession,
                      currentSnapshotSyncV2WorkID == expectedWorkID,
                      snapshotSyncV2Session == expectedSnapshotSession else { return false }
                let importedCreatedAt = imported.documentCreatedAt
                let localResources = try SyncV2PortableMetadata.resourcesForLocalMirror(
                    imported.resources,
                    portableCreatedAt: importedCreatedAt
                )
                _ = try await checkpointSnapshotSyncV2(
                    using: application,
                    workID: importedWorkID,
                    document: imported.document,
                    reason: .migration,
                    documentCreatedAt: Self.normalizedSnapshotSyncV2Date(imported.documentCreatedAt),
                    attachments: imported.attachments,
                    resources: localResources
                )
                guard documentSessionToken == expectedDocumentSession,
                      currentSnapshotSyncV2WorkID == expectedWorkID,
                      snapshotSyncV2Session == expectedSnapshotSession else { return false }
                guard installV2Document(
                    imported.document,
                    workID: importedWorkID,
                    createdAt: imported.documentCreatedAt,
                    attachments: imported.attachments,
                    resources: localResources,
                    portableCreatedAt: importedCreatedAt,
                    expectedWorkID: importedWorkID,
                    expectedDocumentID: imported.document.id
                ) else {
                    externalDocumentOpenErrorMessage = "作品を取り込めませんでした。"
                    return false
                }
                snapshotSyncV2Session = await application.beginSession(workID: importedWorkID)
                startupState = .ready
                Task { @MainActor [weak self] in
                    await self?.refreshSnapshotLibrary()
                }
                return true
            } catch {
                externalDocumentOpenErrorMessage = "作品を取り込めませんでした。"
                return false
            }
        }
    }

    @discardableResult
    func installV2Document(
        _ document: NovelDocument,
        workID: WorkID,
        createdAt: Date,
        attachments: [SyncAttachment] = [],
        resources: [PortableResource] = [],
        portableCreatedAt: Date? = nil,
        expectedWorkID: WorkID? = nil,
        expectedDocumentID: UUID? = nil
    ) -> Bool {
        guard expectedWorkID == nil || expectedWorkID == workID,
              expectedDocumentID == nil || expectedDocumentID == document.id else {
            return false
        }
        let portableMirror: (portableCreatedAt: Date?, resources: [PortableResource])
        do {
            portableMirror = try SyncV2PortableMetadata.splitLocalMirrorResources(resources)
        } catch {
            return false
        }
        self.document = document
        snapshotSyncV2Attachments = attachments
        snapshotSyncV2Resources = portableMirror.resources
        snapshotSyncV2PortableCreatedAt = portableCreatedAt ?? portableMirror.portableCreatedAt
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
        documentSessionToken = WorkspaceSessionToken(
            generation: editorContentGeneration,
            documentID: document.id,
            workID: workID
        )
        snapshotSyncV2ActiveWorkID = workID
        writingProgress.install(document, workID: workID.rawValue)
        snapshotSyncV2DocumentCreatedAt = Self.normalizedSnapshotSyncV2Date(createdAt)
        userDefaults.removeObject(forKey: "fuminiwa.v2.startInLibrary")
        userDefaults.set(workID.rawValue.uuidString, forKey: "fuminiwa.v2.activeWorkID")
        snapshotSyncV2Session = nil
        saveState = .saved
        return true
    }

    @discardableResult
    func createNewV2Document() async -> Bool {
        guard let application = snapshotSyncV2Application,
              permitsNewDocument else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsNewDocument,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            cancelSnapshotSyncV2BackgroundOperations()
            let expectedDocumentSession = documentSessionToken
            let expectedWorkID = currentSnapshotSyncV2WorkID
            let expectedSnapshotSession = snapshotSyncV2Session
            if expectedWorkID != nil, saveState != .saved {
                guard await saveNow() else { return false }
            }
            let fresh = NovelDocument.newDocument()
            let freshWorkID = WorkID(UUID())
            let freshCreatedAt = Self.normalizedSnapshotSyncV2Date(Date())
            guard documentSessionToken == expectedDocumentSession,
                  currentSnapshotSyncV2WorkID == expectedWorkID,
                  snapshotSyncV2Session == expectedSnapshotSession else { return false }
            do {
                _ = try await checkpointSnapshotSyncV2(
                    using: application,
                    workID: freshWorkID,
                    document: fresh,
                    reason: .navigation,
                    documentCreatedAt: freshCreatedAt
                )
            } catch {
                return false
            }
            guard documentSessionToken == expectedDocumentSession,
                  currentSnapshotSyncV2WorkID == expectedWorkID,
                  snapshotSyncV2Session == expectedSnapshotSession else { return false }
            guard installV2Document(
                fresh,
                workID: freshWorkID,
                createdAt: freshCreatedAt,
                expectedWorkID: freshWorkID,
                expectedDocumentID: fresh.id
            ) else { return false }
            snapshotSyncV2Session = await application.beginSession(workID: freshWorkID)
            startupState = .ready
            Task { @MainActor [weak self] in
                await self?.refreshSnapshotLibrary()
            }
            return true
        }
    }

    /// Explicitly copies an unbound local work into the signed-in account.
    /// The source WorkID remains untouched; the newly-created WorkID becomes
    /// the editor session so later checkpoints cannot silently rebind the
    /// original unbound work.
    @discardableResult
    func cloneCurrentWorkIntoActiveAccount(rescueLocally: Bool = false) async -> Bool {
        guard rescueLocally || canCloneCurrentWorkIntoActiveAccount,
              permitsDocumentTransitionOperation,
              let application = snapshotSyncV2Application,
              let sourceWorkID = currentSnapshotSyncV2WorkID else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentTransitionOperation,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            cancelSnapshotSyncV2BackgroundOperations()
            guard await saveNow() else { return false }
            do {
                let newWorkID = WorkID(UUID()), newDocumentID = DocumentID(UUID())
                if rescueLocally {
                    _ = try await application.rescueLocalWork(sourceWorkID: sourceWorkID,
                                                              newWorkID: newWorkID, newDocumentID: newDocumentID)
                } else {
                    _ = try await application.cloneWorkIntoActiveAccount(sourceWorkID: sourceWorkID,
                                                                         newWorkID: newWorkID, newDocumentID: newDocumentID)
                }
                let opened = try await application.openLocal(workID: newWorkID)
                guard let cloned = opened.document else { return false }
                guard installV2Document(
                    cloned,
                    workID: opened.workID,
                    createdAt: opened.documentCreatedAt,
                    attachments: opened.attachments,
                    resources: opened.resources,
                    expectedWorkID: newWorkID,
                    expectedDocumentID: newDocumentID.rawValue
                ) else { return false }
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                snapshotSyncCurrentWorkAccountState = rescueLocally ? .unbound : .active
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
