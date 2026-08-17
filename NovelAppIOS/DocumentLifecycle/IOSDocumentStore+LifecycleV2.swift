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
                try await reloadLibraryItems()
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
        guard await configureSnapshotSyncV2() else { return false }
        let value = NovelDocument.newDocument()
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            return await performDocumentTransition {
                guard snapshotSyncV2Application != nil else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                document = value
                // Portable manifests retain millisecond precision. Keep the
                // in-memory anchor at that precision too, so an explicit
                // export can round-trip the current work date byte-for-byte
                // through ISO8601 without reintroducing filesystem time.
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
        guard await configureSnapshotSyncV2() else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            return await performDocumentTransition {
                guard let location = privateWorkingCopyLocation else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                let staging = try location.stagingDestination()
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try fileManager.copyItem(at: sourceURL, to: staging)
                    let portable = try await portableBridge.importExplicitPackage(from: staging)
                    let loaded = portable.document
                    let syncAttachments = portable.attachments
                    let loadedAttachments = syncAttachments.map {
                        Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
                    }
                    guard install(
                        loaded,
                        at: libraryRoot,
                        attachments: loadedAttachments,
                        rememberRecent: false,
                        workID: WorkID(UUID())
                    ) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    // The package manifest is the explicit portable boundary;
                    // filesystem timestamps are not document identity or
                    // authoring metadata.
                    documentCreatedAt = portable.documentCreatedAt
                    adoptV2AttachmentRecords(syncAttachments)
                    syncV2PortableResources = portable.resources
                    guard await checkpointSnapshotSyncV2(
                        loaded,
                        reason: .migration,
                        resources: portable.resources
                    ) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
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
                _ = await saveNow()
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
        do {
            guard snapshotSyncV2Application != nil,
                  syncV2ActiveWorkID != nil,
                  await saveNow() else {
                throw SyncV2ApplicationError.invalidRuntimeMode
            }
            let root = fileManager.temporaryDirectory.appendingPathComponent(
                "FUMINIWA-Export-\(UUID())",
                isDirectory: true
            )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(
                Self.portableExportFilename(for: document.title),
                isDirectory: true
            )
            guard let attachments = currentV2Attachments() else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            try await portableBridge.exportExplicitPackage(
                document: document,
                attachments: attachments,
                documentCreatedAt: documentCreatedAt,
                resources: syncV2PortableResources,
                to: destination
            )
            pendingExportRootURL = root
            pendingExportURL = destination
        } catch {
            operationErrorMessage = "作品を書き出せませんでした。\n\(error.localizedDescription)"
        }
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
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}
