import Foundation
import NovelCore

extension IOSDocumentStore {
    func bootstrap() async {
        if hasCompletedBootstrap {
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap()
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
        hasCompletedBootstrap = true
    }

    private func performBootstrap() async {
        startupState = .loading
        do {
            try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            try await reloadLibraryItems()
            let recentName = userDefaults.string(forKey: Self.lastDocumentNameKey)
            if let recentName {
                let recentID = IOSPrivateDocumentID(packageName: recentName)
                if Self.isValidPrivatePackageName(recentName) {
                    let didActivate = await activatePrivateDocumentIfAvailable(id: recentID)
                    if didActivate {
                        startupState = .ready
                        saveState = .saved
                        try await reloadLibraryItems()
                        return
                    }
                }
            }

            startupState = .library
            saveState = .saved
            try await reloadLibraryItems()
        } catch {
            startupState = .recovery(message: "作品を安全に開けませんでした。元の作品は変更していません。\n\(error.localizedDescription)")
        }
    }

    @discardableResult
    func makeNewDocument() async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            let transitioned = await performDocumentTransition {
                let newDocument = NovelDocument.newDocument()
                let newURL = uniquePackageURL(for: newDocument.id)
                try await repository.save(newDocument, to: newURL)
                let newAttachments = try await loadAttachmentsForInstall(at: newURL)
                install(newDocument, at: newURL, attachments: newAttachments)
                startupState = .ready
                saveState = .saved
            }
            if transitioned {
                _ = await refreshLibrary()
            }
            return transitioned
        }
    }

    @discardableResult
    func importPackage(from sourceURL: URL) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            let transitioned = await performDocumentTransition {
                let stagingURL = libraryRoot.appendingPathComponent(
                    ".import-\(UUID().uuidString).novelpkg",
                    isDirectory: true
                )
                let destinationURL = uniquePackageURL(for: UUID())
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    try await Self.copyPackage(from: sourceURL, to: stagingURL)
                    let loaded = try await repository.load(from: stagingURL)
                    try fileManager.moveItem(at: stagingURL, to: destinationURL)
                    let loadedAttachments = try await loadAttachmentsForInstall(at: destinationURL)
                    install(loaded, at: destinationURL, attachments: loadedAttachments)
                    startupState = .ready
                    saveState = .saved
                } catch {
                    try? fileManager.removeItem(at: stagingURL)
                    try? fileManager.removeItem(at: destinationURL)
                    throw error
                }
            }
            if transitioned {
                _ = await refreshLibrary()
            }
            return transitioned
        }
    }

    @discardableResult
    func handleExternalPackageURL(_ url: URL) async -> Bool {
        await bootstrap()
        return await importPackage(from: url)
    }

    func performDocumentTransition(_ operation: () async throws -> Void) async -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        isDocumentTransitionInProgress = true
        operationErrorMessage = nil

        guard editorCommandSession.prepareForDocumentTransition() else {
            operationErrorMessage = "日本語入力を確定できませんでした。変換を確定してから、もう一度お試しください。"
            isDocumentTransitionInProgress = false
            return false
        }
        defer {
            editorCommandSession.resumeAfterDocumentTransition()
            isDocumentTransitionInProgress = false
        }

        if startupState == .ready {
            // `prepareForDocumentTransition()` は、未確定のIME入力をモデルへ同期する。
            // 遷移中は通常の変更通知を止めているため、ここで旧作品を明示的にdirtyにし、
            // 同期された最終本文を必ず旧URLへ保存してから候補作品を扱う。
            saveCoordinator.markDirty()
            guard await saveCoordinator.saveNow() else {
                operationErrorMessage = "現在の作品を保存できなかったため、作品の切り替えを中止しました。"
                return false
            }
        }

        do {
            try await operation()
            return true
        } catch {
            operationErrorMessage = "作品を開けませんでした。元の作品は変更していません。\n\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard startupState == .ready else { return false }
        return await saveCoordinator.saveNow()
    }

    func requestExport() async {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return }
            pendingExportURL = nil
            cleanupPendingExport()

            do {
                let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    let root = fileManager.temporaryDirectory
                        .appendingPathComponent("FUMINIWA-Export-\(UUID().uuidString)", isDirectory: true)
                    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                    let filename = Self.portableExportFilename(for: document.title)
                    let destination = root.appendingPathComponent(filename, isDirectory: true)
                    do {
                        try await repository.saveCopy(
                            document,
                            from: documentURL,
                            to: destination
                        )
                        return (root: root, package: destination)
                    } catch {
                        try? fileManager.removeItem(at: root)
                        throw error
                    }
                }

                switch result {
                case .saveFailedBeforeOperation:
                    operationErrorMessage = "保存に失敗したため、書き出しを開始しませんでした。"
                case let .completed(value, savedAfterOperation):
                    guard savedAfterOperation else {
                        try? fileManager.removeItem(at: value.root)
                        operationErrorMessage = "書き出し中の変更を保存できなかったため、中止しました。"
                        return
                    }
                    pendingExportRootURL = value.root
                    pendingExportURL = value.package
                }
            } catch {
                operationErrorMessage = "作品を書き出せませんでした。\n\(error.localizedDescription)"
            }
        }
    }

    func dismissExport() {
        pendingExportURL = nil
        cleanupPendingExport()
    }

    private func uniquePackageURL(for id: UUID) -> URL {
        var candidateID = id
        var candidate = libraryRoot.appendingPathComponent("\(candidateID.uuidString).novelpkg", isDirectory: true)
        while fileManager.fileExists(atPath: candidate.path) {
            candidateID = UUID()
            candidate = libraryRoot.appendingPathComponent("\(candidateID.uuidString).novelpkg", isDirectory: true)
        }
        return candidate
    }

    private func cleanupPendingExport() {
        guard let pendingExportRootURL else { return }
        try? fileManager.removeItem(at: pendingExportRootURL)
        self.pendingExportRootURL = nil
    }

    func install(
        _ document: NovelDocument,
        at url: URL,
        attachments: [Attachment],
        rememberRecent: Bool = true
    ) {
        self.document = document
        documentURL = url
        advanceDocumentSessionGeneration()
        replaceAttachments(attachments)
        selectedChapterID = document.chapters.first?.id
        selectedEpisodeID = document.chapters.first?.episodes.first?.id
        if rememberRecent {
            userDefaults.set(url.lastPathComponent, forKey: Self.lastDocumentNameKey)
        }
    }

    static func defaultLibraryRoot(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("FUMINIWA/Works", isDirectory: true)
    }

    static func portableExportFilename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let cleaned = title.unicodeScalars
            .map { forbidden.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "新規作品" : String(cleaned.prefix(80))
        return "\(base).novelpkg"
    }
}
