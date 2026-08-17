import Foundation
import NovelCore
import NovelSyncV2Application

extension IOSDocumentStore {
    func performCoordinatedDocumentSave(_ value: NovelDocument, to _: URL) async throws {
        guard snapshotSyncV2Application != nil else {
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
                if let name = userDefaults.string(forKey: Self.lastDocumentNameKey),
                   let uuid = UUID(uuidString: name.replacingOccurrences(of: ".novelpkg", with: "")) {
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
                documentCreatedAt = Date()
                documentURL = libraryRoot.appendingPathComponent(
                    value.id.uuidString, isDirectory: false
                )
                try fileManager.createDirectory(at: documentURL, withIntermediateDirectories: true)
                userDefaults.set(value.id.uuidString, forKey: Self.lastDocumentNameKey)
                replaceAttachments([])
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
        await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            return await performDocumentTransition {
                guard let location = privateWorkingCopyLocation else { throw IOSPrivateWorkingCopyLocationError.unsafeRoot }
                let staging = try location.stagingDestination()
                let destination = try location.destination(for: IOSPrivateDocumentID(packageName: "\(UUID().uuidString).novelpkg"))
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try fileManager.copyItem(at: sourceURL, to: staging)
                    let loaded = try await repository.load(from: staging)
                    try fileManager.moveItem(at: staging, to: destination)
                    guard install(loaded, at: destination, attachments: []) else { throw IOSPrivateWorkingCopyLocationError.unsafeRoot }
                    startupState = .ready
                    saveState = .saved
                } catch {
                    try? fileManager.removeItem(at: staging)
                    try? fileManager.removeItem(at: destination)
                    throw error
                }
            }
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
        guard let portable = repository as? any PortableDocumentPackageRepository else {
            operationErrorMessage = "この環境では書き出しを利用できません。"
            return
        }
        do {
            let root = fileManager.temporaryDirectory.appendingPathComponent("FUMINIWA-Export-\(UUID())", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("source.novelpkg", isDirectory: true)
            let destination = root.appendingPathComponent(Self.portableExportFilename(for: document.title), isDirectory: true)
            try await repository.save(document, to: source)
            try await portable.saveValidatedCopy(document, from: source, to: destination)
            _ = try await portable.validatePortablePackage(at: destination)
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
    func install(_ value: NovelDocument, at url: URL, attachments: [Attachment], rememberRecent: Bool = true) -> Bool {
        document = value
        documentCreatedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        documentURL = url.standardizedFileURL
        replaceAttachments(attachments)
        selectedChapterID = value.chapters.first?.id
        selectedEpisodeID = value.chapters.first?.episodes.first?.id
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        if rememberRecent {
            userDefaults.set(url.lastPathComponent, forKey: Self.lastDocumentNameKey)
        }
        startupState = .ready
        return true
    }

    static func defaultLibraryRoot(fileManager: FileManager) -> URL {
        (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
            .appendingPathComponent("FUMINIWA/Works", isDirectory: true)
    }

    static func portableExportFilename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let clean = title.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clean.isEmpty ? "新規作品" : String(clean.prefix(80))).novelpkg"
    }
}
