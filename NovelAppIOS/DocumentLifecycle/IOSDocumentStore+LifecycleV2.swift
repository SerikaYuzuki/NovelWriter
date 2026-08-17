import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge

extension IOSDocumentStore {
    func performCoordinatedDocumentSave(_ value: NovelDocument) async throws {
        guard snapshotSyncV2Application != nil, syncV2ActiveWorkID != nil else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        guard await checkpointSnapshotSyncV2(value, reason: .autosave) else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
    }

    func bootstrap(localFirst _: Bool = true) async {
        guard !deviceSyncStartupFailedSafely, !hasCompletedBootstrap else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard await configureSnapshotSyncV2() else {
            startupState = .recovery(message: "本文を保存するSQLite runtimeを準備できませんでした。")
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            startupState = .loading
            do {
                guard try await reloadLibraryItems() else {
                    startupState = .library
                    saveState = .saved
                    return
                }
                if let name = userDefaults.string(forKey: Self.lastWorkIDKey),
                   let uuid = UUID(uuidString: name) {
                    _ = await openSnapshotSyncV2(workID: uuid)
                }
                if startupState != .ready {
                    startupState = .library
                    saveState = .saved
                }
            } catch {
                startupState = .recovery(message: "作品を安全に開けませんでした。\n\(error.localizedDescription)")
            }
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
        hasCompletedBootstrap = true
    }

    @discardableResult
    func makeNewDocument() async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              await configureSnapshotSyncV2() else { return false }
        let value = NovelDocument.newDocument()
        return await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2AccountTransitionActive else { return false }
            return await performDocumentTransition {
                guard !isSyncV2AccountTransitionActive,
                      snapshotSyncV2Application != nil else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                document = value
                // Snapshot Sync v2 and the portable bridge use UTC whole
                // seconds for the document anchor. Normalize at creation so
                // the SQLite value remains stable across every reopen/export.
                documentCreatedAt = Self.portableDatePrecision(Date())
                let workID = WorkID(UUID())
                syncV2ActiveWorkID = workID
                syncV2KeepBothPendingWorkID = nil
                // WorkID + SQLite is the normal identity.  `documentURL` is
                // not a per-work working copy and no WorkID directory is
                // created for a normal new document.
                documentURL = libraryRoot.standardizedFileURL
                userDefaults.set(workID.rawValue.uuidString, forKey: Self.lastWorkIDKey)
                replaceAttachments([])
                syncV2AttachmentPayloads = [:]
                syncV2AttachmentIDs = [:]
                syncV2PortableResources = []
                syncV2PortableCreatedAt = nil
                selectedChapterID = value.chapters.first?.id
                selectedEpisodeID = value.chapters.first?.episodes.first?.id
                advanceDocumentSessionGeneration()
                advanceEditorContentGeneration()
                startupState = .ready
                guard await checkpointSnapshotSyncV2(value, reason: .explicit) else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                saveState = .saved
            }
        }
    }

    @discardableResult
    func importPackage(from sourceURL: URL) async -> Bool {
        guard !isSyncV2AccountTransitionActive else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        let expectedSession = currentDocumentSessionToken
        let expectedWorkID = syncV2ActiveWorkID
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard (try? IOSPrivateWorkingCopyLocation.validateExplicitPackageSource(sourceURL)) != nil else {
            operationErrorMessage = "読み込める作品パッケージを選択できませんでした。"
            return false
        }
        guard await configureSnapshotSyncV2(),
              matchesSnapshotSyncV2OperationSource(
                  session: expectedSession, workID: expectedWorkID, accountScope: expectedAccountScope
              ) else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  !isSyncV2AccountTransitionActive,
                  matchesSnapshotSyncV2OperationSource(
                      session: expectedSession, workID: expectedWorkID, accountScope: expectedAccountScope
                  ) else { return false }
            return await performDocumentTransition {
                guard matchesSnapshotSyncV2OperationSource(
                    session: expectedSession, workID: expectedWorkID, accountScope: expectedAccountScope
                ),
                    let location = privateWorkingCopyLocation else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                let sourceAttestation = try IOSPrivateWorkingCopyLocation
                    .attestExplicitPackageSource(sourceURL)
                let staging = try location.stagingDestination()
                do {
                    try fileManager.copyItem(at: sourceURL, to: staging)
                    let stagedAttestation = try location.attestStagingPackage(at: staging)
                    try IOSPrivateWorkingCopyLocation.revalidate(sourceAttestation)
                    guard stagedAttestation.treeDigest == sourceAttestation.treeDigest else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    let portable = try await portableBridge.importExplicitPackage(from: staging)
                    guard matchesSnapshotSyncV2OperationSource(
                        session: expectedSession, workID: expectedWorkID, accountScope: expectedAccountScope
                    ) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    try IOSPrivateWorkingCopyLocation.revalidate(sourceAttestation)
                    try location.revalidate(stagedAttestation)
                    let loaded = portable.document
                    let syncAttachments = portable.attachments
                    guard validateV2AttachmentRecords(syncAttachments) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    let loadedAttachments = syncAttachments.map {
                        Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
                    }
                    let importedWorkID = WorkID(UUID())
                    let localResources = try SyncV2PortableMetadata.resourcesForLocalMirror(
                        portable.resources,
                        portableCreatedAt: portable.documentCreatedAt
                    )
                    // Build the imported Work in SQLite before changing the
                    // active editor. If this checkpoint fails, the current
                    // session remains untouched and the staged package is
                    // retained for recovery/archive.
                    guard let application = snapshotSyncV2Application else {
                        throw SyncV2ApplicationError.invalidRuntimeMode
                    }
                    _ = try await application.checkpoint(
                        workID: importedWorkID,
                        document: loaded,
                        reason: .migration,
                        documentCreatedAt: Self.portableDatePrecision(portable.documentCreatedAt),
                        attachments: syncAttachments,
                        resources: localResources
                    )
                    guard matchesSnapshotSyncV2OperationSource(
                        session: expectedSession, workID: expectedWorkID, accountScope: expectedAccountScope
                    ),
                        install(
                            loaded,
                            at: libraryRoot,
                            attachments: loadedAttachments,
                            rememberRecent: false,
                            workID: importedWorkID
                        ) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    // The package manifest is the explicit portable boundary;
                    // filesystem timestamps are not document identity or
                    // authoring metadata.
                    documentCreatedAt = Self.portableDatePrecision(portable.documentCreatedAt)
                    syncV2PortableCreatedAt = portable.documentCreatedAt
                    guard adoptV2AttachmentRecords(syncAttachments) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    syncV2PortableResources = portable.resources
                    archiveImportedPackage(at: staging)
                    startupState = .ready
                    saveState = .saved
                } catch {
                    archiveImportedPackage(at: staging)
                    throw error
                }
            }
        }
    }

    private func archiveImportedPackage(at staging: URL) {
        let archiveRoot = libraryRoot
            .appendingPathComponent("Legacy", isDirectory: true)
            .appendingPathComponent("ImportedPackages", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: archiveRoot,
                withIntermediateDirectories: true
            )
            let archiveURL = archiveRoot.appendingPathComponent(
                "\(UUID().uuidString).novelpkg",
                isDirectory: true
            )
            try fileManager.moveItem(at: staging, to: archiveURL)
        } catch {
            // The SQLite checkpoint is already authoritative.  Leaving the
            // staging copy in place is safer than deleting an imported source.
        }
    }

    func handleExternalPackageURL(_ url: URL) async -> Bool {
        await bootstrap()
        return await importPackage(from: url)
    }

    func performDocumentTransition(_ operation: () async throws -> Void) async -> Bool {
        guard !deviceSyncStartupFailedSafely, !isDocumentTransitionInProgress else { return false }
        guard editorCommandSession.prepareForDocumentTransition() else {
            operationErrorMessage = "日本語入力を確定できませんでした。"
            return false
        }
        isDocumentTransitionInProgress = true
        defer {
            editorCommandSession.resumeAfterDocumentTransition()
            isDocumentTransitionInProgress = false
        }
        do {
            if startupState == .ready {
                guard await saveNow() else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
            }
            try await operation()
            return true
        } catch {
            operationErrorMessage = "作品を操作できませんでした。\n\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard startupState == .ready else { return false }
        return await saveCoordinator.saveNow()
    }

    func requestExport() async {
        guard !isSyncV2AccountTransitionActive,
              let expectedSession = currentDocumentSessionToken,
              let expectedWorkID = syncV2ActiveWorkID else { return }
        let expectedAccountScope = snapshotSyncV2AccountScope
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  !isSyncV2AccountTransitionActive,
                  currentDocumentSessionToken == expectedSession,
                  syncV2ActiveWorkID == expectedWorkID,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return }
            _ = await performDocumentTransition {
                guard !isSyncV2AccountTransitionActive,
                      currentDocumentSessionToken == expectedSession,
                      syncV2ActiveWorkID == expectedWorkID,
                      snapshotSyncV2AccountScope == expectedAccountScope,
                      snapshotSyncV2Application != nil,
                      let attachments = currentV2Attachments() else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                let root = fileManager.temporaryDirectory.appendingPathComponent(
                    "FUMINIWA-Export-\(UUID())",
                    isDirectory: true
                )
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                var keepsExport = false
                defer {
                    if !keepsExport {
                        try? fileManager.removeItem(at: root)
                    }
                }
                let destination = root.appendingPathComponent(
                    Self.portableExportFilename(for: document.title),
                    isDirectory: true
                )
                let exportResources = try SyncV2PortableMetadata.resourcesForExport(
                    syncV2PortableResources
                )
                try await portableBridge.exportExplicitPackage(
                    document: document,
                    attachments: attachments,
                    documentCreatedAt: syncV2PortableCreatedAt ?? documentCreatedAt,
                    resources: exportResources,
                    to: destination
                )
                guard !isSyncV2AccountTransitionActive,
                      currentDocumentSessionToken == expectedSession,
                      syncV2ActiveWorkID == expectedWorkID,
                      snapshotSyncV2AccountScope == expectedAccountScope else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                pendingExportRootURL = root
                pendingExportURL = destination
                keepsExport = true
            }
        }
    }

    private func matchesSnapshotSyncV2OperationSource(
        session: IOSDocumentSessionToken?,
        workID: WorkID?,
        accountScope: IOSSnapshotSyncV2AccountScope
    ) -> Bool {
        !isSyncV2AccountTransitionActive
            && currentDocumentSessionToken == session
            && syncV2ActiveWorkID == workID
            && snapshotSyncV2AccountScope == accountScope
    }

    func dismissExport() {
        pendingExportURL = nil
        if let root = pendingExportRootURL {
            try? fileManager.removeItem(at: root)
        }
        pendingExportRootURL = nil
    }

    @discardableResult
    func install(
        _ value: NovelDocument,
        at url: URL,
        attachments: [Attachment],
        rememberRecent: Bool = true,
        workID: WorkID? = nil
    ) -> Bool {
        if snapshotSyncV2Application != nil, workID == nil {
            return false
        }
        document = value
        documentCreatedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        documentURL = snapshotSyncV2Application == nil
            ? url.standardizedFileURL
            : libraryRoot.standardizedFileURL
        if snapshotSyncV2Application != nil {
            syncV2ActiveWorkID = workID
            syncV2KeepBothPendingWorkID = nil
        }
        replaceAttachments(attachments)
        syncV2AttachmentPayloads = [:]
        syncV2AttachmentIDs = [:]
        syncV2PortableResources = []
        syncV2PortableCreatedAt = nil
        selectedChapterID = value.chapters.first?.id
        selectedEpisodeID = value.chapters.first?.episodes.first?.id
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        if rememberRecent {
            userDefaults.set(url.lastPathComponent, forKey: Self.lastDocumentNameKey)
        }
        if snapshotSyncV2Application != nil {
            userDefaults.set(syncV2ActiveWorkID?.rawValue.uuidString, forKey: Self.lastWorkIDKey)
        }
        startupState = .ready
        return true
    }

    static func defaultLibraryRoot(fileManager: FileManager) -> URL {
        (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent("FUMINIWA/Works", isDirectory: true)
    }

    static func portableExportFilename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let clean = title.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clean.isEmpty ? "新規作品" : String(clean.prefix(80))).novelpkg"
    }

    private static func portableDatePrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
