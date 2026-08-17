import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    func bootstrap(localFirst: Bool = false) async {
        guard !deviceSyncStartupFailedSafely else { return }
        if hasCompletedBootstrap {
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap(localFirst: localFirst)
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
        hasCompletedBootstrap = true
    }

    private func performBootstrap(localFirst: Bool) async {
        guard !deviceSyncStartupFailedSafely else { return }
        startDeviceSyncSignalObservationIfNeeded()
        startupState = .loading
        if usesCloudLibrary {
            startupState = .library
            saveState = .saved
            if localFirst {
                // 端末内の検証済みコピーだけを先に棚へ出す。CloudKitの確認は
                // FuminiwaIOSAppのbootstrap完了後にバックグラウンドで開始する。
                _ = await refreshLocalCloudLibrary()
            } else {
                _ = await refreshCloudLibrary()
            }
            return
        }
        do {
            guard let privateWorkingCopyLocation else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            try privateWorkingCopyLocation.validateFixedRoot()
            try await reloadLibraryItems()
            guard !deviceSyncStartupFailedSafely else { return }
            let recentName = userDefaults.string(forKey: Self.lastDocumentNameKey)
            if let recentName {
                let recentID = IOSPrivateDocumentID(packageName: recentName)
                if Self.isValidPrivatePackageName(recentName) {
                    let didActivate = await activatePrivateDocumentIfAvailable(id: recentID)
                    if didActivate {
                        guard !deviceSyncStartupFailedSafely else { return }
                        startupState = .ready
                        saveState = .saved
                        try await reloadLibraryItems()
                        return
                    }
                }
            }

            guard !deviceSyncStartupFailedSafely else { return }
            startupState = .library
            saveState = .saved
            try await reloadLibraryItems()
        } catch {
            guard !deviceSyncStartupFailedSafely else { return }
            startupState = .recovery(message: "作品を安全に開けませんでした。元の作品は変更していません。\n\(error.localizedDescription)")
        }
    }

    @discardableResult
    func makeNewDocument() async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        if usesCloudLibrary {
            return await makeNewCloudLibraryDocument()
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            let transitioned = await performDocumentTransition {
                guard let privateWorkingCopyLocation else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                let newDocument = NovelDocument.newDocument()
                let newURL = try uniquePackageURL(for: newDocument.id)
                try privateWorkingCopyLocation.validateFixedRoot()
                try await repository.save(newDocument, to: newURL)
                let attestation = try privateWorkingCopyLocation.attestPackage(at: newURL)
                let newAttachments = try await loadAttachmentsForInstall(at: newURL)
                try privateWorkingCopyLocation.revalidate(attestation)
                guard !deviceSyncStartupFailedSafely else { throw CancellationError() }
                guard install(newDocument, at: newURL, attachments: newAttachments) else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
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
        guard !deviceSyncStartupFailedSafely else { return false }
        if usesCloudLibrary {
            return await importCloudLibraryPackage(from: sourceURL)
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            let transitioned = await performDocumentTransition {
                try await installImportedPackage(from: sourceURL)
            }
            if transitioned {
                _ = await refreshLibrary()
            }
            return transitioned
        }
    }

    private func installImportedPackage(from sourceURL: URL) async throws {
        guard let privateWorkingCopyLocation else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let stagingURL = try privateWorkingCopyLocation.stagingDestination()
        let destinationURL = try uniquePackageURL(for: UUID())
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await Self.copyPackage(from: sourceURL, to: stagingURL)
            let stagingAttestation = try privateWorkingCopyLocation.attestStagingPackage(at: stagingURL)
            let loaded = try await repository.load(from: stagingURL)
            try privateWorkingCopyLocation.revalidate(stagingAttestation)
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            let destinationAttestation = try privateWorkingCopyLocation.attestMovedPackage(
                at: destinationURL,
                matching: stagingAttestation
            )
            let loadedAttachments = try await loadAttachmentsForInstall(at: destinationURL)
            try privateWorkingCopyLocation.revalidate(destinationAttestation)
            guard !deviceSyncStartupFailedSafely else { throw CancellationError() }
            guard install(loaded, at: destinationURL, attachments: loadedAttachments) else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            startupState = .ready
            saveState = .saved
        } catch {
            privateWorkingCopyLocation.removeOwnedItemIfSafe(at: stagingURL, allowsStaging: true)
            privateWorkingCopyLocation.removeOwnedItemIfSafe(at: destinationURL, allowsStaging: false)
            throw error
        }
    }

    @discardableResult
    func handleExternalPackageURL(_ url: URL) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        await bootstrap()
        guard !deviceSyncStartupFailedSafely else { return false }
        return await importPackage(from: url)
    }

    func performDocumentTransition(_ operation: () async throws -> Void) async -> Bool {
        guard !deviceSyncStartupFailedSafely, !isDocumentTransitionInProgress else { return false }
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
            // packageを先に保存し、同期中の作品ならjournal保存・best effort publish・
            // lease解放までを終えてから候補作品を扱う。
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else {
                operationErrorMessage = "現在の作品を保存できなかったため、作品の切り替えを中止しました。"
                return false
            }
        }

        do {
            try await operation()
            return true
        } catch {
            operationErrorMessage = if usesCloudLibrary {
                "作品を準備できませんでした。元の作品は変更していません。通信状態とサインイン状態を確認して、もう一度お試しください。"
            } else {
                "作品を開けませんでした。元の作品は変更していません。\n\(error.localizedDescription)"
            }
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
                    guard let portable = repository as? PortableDocumentPackageRepository,
                          let privateWorkingCopyLocation else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    let sourceURL = documentURL.standardizedFileURL
                    let documentSnapshot = document
                    let sourceAttestation = try privateWorkingCopyLocation.attestPackage(
                        at: sourceURL
                    )
                    let root = fileManager.temporaryDirectory
                        .appendingPathComponent("FUMINIWA-Export-\(UUID().uuidString)", isDirectory: true)
                    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                    let filename = Self.portableExportFilename(for: document.title)
                    let destination = root.appendingPathComponent(filename, isDirectory: true)
                    do {
                        try privateWorkingCopyLocation.revalidate(sourceAttestation)
                        try await portable.saveValidatedCopy(
                            documentSnapshot,
                            from: sourceURL,
                            to: destination
                        )
                        let readback = try await portable.validatePortablePackage(at: destination)
                        guard readback == documentSnapshot,
                              try WorkSnapshot(document: readback)
                              == WorkSnapshot(document: documentSnapshot) else {
                            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                        }
                        try privateWorkingCopyLocation.revalidate(sourceAttestation)
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
                operationErrorMessage = if usesCloudLibrary {
                    "作品を書き出せませんでした。保存先と空き容量を確認して、もう一度お試しください。"
                } else {
                    "作品を書き出せませんでした。\n\(error.localizedDescription)"
                }
            }
        }
    }

    func dismissExport() {
        pendingExportURL = nil
        cleanupPendingExport()
    }

    private func uniquePackageURL(for id: UUID) throws -> URL {
        guard let privateWorkingCopyLocation else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        var candidateID = id
        while true {
            do {
                return try privateWorkingCopyLocation.destination(
                    for: IOSPrivateDocumentID(packageName: "\(candidateID.uuidString).novelpkg")
                )
            } catch IOSPrivateWorkingCopyLocationError.destinationExists {
                candidateID = UUID()
            }
        }
    }

    private func cleanupPendingExport() {
        guard let pendingExportRootURL else { return }
        try? fileManager.removeItem(at: pendingExportRootURL)
        self.pendingExportRootURL = nil
    }

    @discardableResult
    func install(
        _ document: NovelDocument,
        at url: URL,
        attachments: [Attachment],
        rememberRecent: Bool = true
    ) -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        guard let privateWorkingCopyLocation,
              (try? privateWorkingCopyLocation.attestPackage(at: url)) != nil else {
            failStartupForDeviceSyncSafety()
            return false
        }
        self.document = document
        documentURL = url.standardizedFileURL
        noteDeviceSyncPackageSaved(document)
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        replaceAttachments(attachments)
        selectedChapterID = document.chapters.first?.id
        selectedEpisodeID = document.chapters.first?.episodes.first?.id
        deviceSyncSelectionDidChange()
        cancelAutomaticSnapshotScheduling()
        lastAutomaticSnapshotRevision = saveCoordinator.lastSavedRevision
        if rememberRecent {
            userDefaults.set(url.lastPathComponent, forKey: Self.lastDocumentNameKey)
        }
        if usesSnapshotSyncRuntime {
            Task { @MainActor [weak self] in
                await self?.ensureLocalSnapshotSeeded(for: document)
            }
        }
        return true
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
