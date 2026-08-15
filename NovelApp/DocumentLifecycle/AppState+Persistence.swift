import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelLocalStore
import NovelSync

extension AppState {
    private struct LocalManifest: Encodable {
        let schemaVersion: Int
        let workId: UUID
        let parentSnapshotIds: [String]
        let entries: [LocalManifestEntry]
    }

    private struct LocalManifestEntry: Encodable {
        let entityKey: String
        let objectId: String
        let byteCount: Int
        let contentType: String
    }

    /// Commits the same saved NovelDocument to SQLite in one local transaction.
    /// The current runtime uses the document UUID as the provisional WorkID;
    /// the migration ledger can replace this binding without changing the
    /// document identity or the portable package format.
    private func commitLocalCanonicalSnapshot(_ document: NovelDocument) async -> Bool {
        guard let store = localCanonicalStore else { return true }
        do {
            let snapshot = try WorkSnapshot(document: document)
            let objectBytes = try WorkCanonicalJSON.encodeSnapshot(snapshot)
            let objectID = SyncContentDigest(content: String(decoding: objectBytes, as: UTF8.self)).rawValue
            let workID = document.id
            let previous = try await store.workState(for: workID)
            let manifest = LocalManifest(
                schemaVersion: 1,
                workId: workID,
                parentSnapshotIds: previous?.currentLocalSnapshotID.map { [$0] } ?? [],
                entries: [
                    LocalManifestEntry(
                        entityKey: "work/document",
                        objectId: objectID,
                        byteCount: objectBytes.count,
                        contentType: "application/json"
                    )
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let manifestBytes = try encoder.encode(manifest)
            let snapshotID = SyncContentDigest(content: String(decoding: manifestBytes, as: UTF8.self)).rawValue
            let createdAtKey = "fuminiwa.documentCreatedAt.\(document.id.uuidString.lowercased())"
            let createdAt: String
            if let existing = userDefaults.string(forKey: createdAtKey) {
                createdAt = existing
            } else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                createdAt = formatter.string(from: Date())
                userDefaults.set(createdAt, forKey: createdAtKey)
            }
            _ = try await store.commitSnapshot(
                workID: workID,
                documentID: document.id,
                documentCreatedAt: createdAt,
                snapshotID: snapshotID,
                parentSnapshotIDs: manifest.parentSnapshotIds,
                manifest: manifestBytes,
                objects: [LocalObject(objectID: objectID, bytes: objectBytes)],
                reason: .autosave
            )
            return true
        } catch {
            print("[FUMINIWA] SQLite正本への保存に失敗しました(\(Self.errorCategory(error)))")
            return false
        }
    }

    func performCoordinatedDocumentSave(
        _ document: NovelDocument,
        to url: URL
    ) async throws {
        do {
            // Post-cutover the editor must not enter the legacy CloudKit
            // preparation gate. SQLite commit is the local durability
            // boundary; the Rust worker is scheduled only after it succeeds.
            // Keep writing the portable package for the import/export bridge
            // until that bridge is fully detached from the live document URL.
            if usesSnapshotSyncRuntime {
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                guard await recordLocalLibraryPackageSave(document, at: url) else {
                    deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                    return
                }
                deviceSyncLocalDurabilityState = .saved
                deviceSyncTransferState = .notApplicable
                return
            }

            let workPreparation = await stageWorkSyncPackageSave(document)
            switch workPreparation {
            case .notApplicable:
                break
            case .failed:
                // journalが失敗しても、利用者の原稿はpackageへ退避する。
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                _ = await recordLocalLibraryPackageSave(document, at: url)
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                return
            case let .prepared(preparation):
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                guard await recordLocalLibraryPackageSave(document, at: url) else {
                    deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                    return
                }
                await confirmWorkSyncPackageSave(preparation)
                return
            case let .notePrepared(preparation):
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                guard await recordLocalLibraryPackageSave(document, at: url) else {
                    deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                    return
                }
                await confirmNoteSyncPackageSave(preparation)
                return
            }
            let intentReady = await flushPendingDeviceSyncEditIntents()
            let checkpoints = await prepareDeviceSyncPackageCheckpoints(for: document, at: url)
            try await repository.save(document, to: url)
            noteDeviceSyncPackageSaved(document)
            guard await recordLocalLibraryPackageSave(document, at: url) else {
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                return
            }
            let checkpointsCommitted = await commitDeviceSyncPackageCheckpoints(checkpoints)
            if !intentReady || !checkpoints.allPrepared || !checkpointsCommitted {
                deviceSyncLocalDurabilityState = .failed
            }
        } catch {
            // 保存失敗でアプリを落とさない。まずはログのみ残し、執筆継続を優先する。
            print("[FUMINIWA] 保存に失敗しました(\(Self.errorCategory(error)))")
            throw error
        }
    }

    /// App-private packageのreadback exactを確認してからlocal library recordを更新する。
    /// Work journalのmaterialization confirmより先に耐久化し、registry失敗時はremote
    /// confirmを止めることでfalse checkmarkと未追跡uploadを防ぐ。
    private func recordLocalLibraryPackageSave(
        _ expectedDocument: NovelDocument,
        at url: URL
    ) async -> Bool {
        guard await commitLocalCanonicalSnapshot(expectedDocument) else { return false }
        scheduleSnapshotSync(for: expectedDocument.id)
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return true }
        do {
            guard let workID = try await library.workIDForPackageURL(url) else { return true }
            try await library.validateInstalledPackage(workID)
            guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                return false
            }
            let readBack = try await portableRepository.validatePortablePackage(at: url)
            guard readBack == expectedDocument,
                  try WorkSnapshot(document: readBack) == WorkSnapshot(document: expectedDocument) else {
                return false
            }
            let attestation = try DeviceSyncLocalPackageAttestation(
                document: readBack,
                updatedAt: runtime.now()
            )
            try await library.recordPackageMutation(workID, attestation)
            return true
        } catch {
            return false
        }
    }

    /// holderのdeinitで一度だけ解除するアプリ非アクティブ通知のtoken。
    // MARK: - 保存

    /// アプリ終了前に、保留中のデバウンス保存をキャンセルして現在状態を保存する。
    func saveBeforeTermination() async -> Bool {
        if let terminationTask {
            return await terminationTask.value
        }

        isTerminationPending = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            let succeeded = await documentOperationGate.perform {
                await saveBeforeTerminationSerially()
            }
            if !succeeded {
                // 終了が取り消された後は、利用者が保存先や作品を変更して復旧できる。
                isTerminationPending = false
                terminationTask = nil
            }
            return succeeded
        }
        terminationTask = task
        return await task.value
    }

    private func saveBeforeTerminationSerially() async -> Bool {
        guard startupState.isReady else { return true }
        guard beginDocumentTransition() else { return false }
        let succeeded = await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        )
        if !succeeded {
            endDocumentTransition()
        }
        return succeeded
    }

    /// Fileメニューの明示保存。自動保存と同じ直列化経路を使う。
    /// iCloudへ結んだ作品の`Cmd+S`は、同じlocal保存のあと明示同期する(D-073)。
    @discardableResult
    func saveNow() async -> Bool {
        guard startupState.isReady else { return false }
        return await saveCoordinator.saveNow()
    }

    /// 自動保存・話切替・終了前保存は使わない。Fileメニューの`Cmd+S`と
    /// 「iCloudと同期」だけが、local flushのあとNote send／pullを始める。
    @discardableResult
    func saveAndSyncNow() async -> Bool {
        DeviceSyncLog.note("explicit requested")
        guard permitsDocumentInteraction else {
            DeviceSyncLog.note("explicit skipped(no-interaction)")
            return false
        }
        // Seal the work/session at the button invocation. `saveNow()` may
        // suspend while a chooser or another lifecycle operation changes the
        // active document; never re-read a new identity and sync that work.
        let expectedSession = documentSessionToken
        let expectedIdentity = activeWorkSyncIdentity
        let saved = await saveNow()
        guard saved else {
            DeviceSyncLog.note("explicit skipped(local-save-failed)")
            return false
        }
        guard documentSessionToken == expectedSession else {
            DeviceSyncLog.note("explicit skipped(stale-session-after-save)")
            return false
        }
        if let expectedIdentity {
            guard activeWorkSyncIdentity == expectedIdentity,
                  workSyncContextIsCurrent(expectedIdentity) else {
                DeviceSyncLog.note("explicit skipped(stale-identity-after-save)")
                return false
            }
            await syncBoundNoteWorkIfNeeded(expectedIdentity: expectedIdentity)
        }
        return saved
    }

    /// 保存失敗後に、現在の未保存 revision を明示的に再試行する。
    func retrySave() {
        guard startupState.isReady else { return }
        flushSaveImmediately()
    }

    /// 保留中のデバウンス保存をキャンセルし、即座に保存キューへ流す(fire-and-forget)。
    /// `saveCoordinator.saveNow()` 自体がデバウンスのキャンセルと dirty 分の
    /// 保存until-cleanを面倒見るため、ここでは呼び出すだけでよい。
    func flushSaveImmediately() {
        guard startupState.isReady else { return }
        Task { await self.saveCoordinator.saveNow() }
    }

    func handleSaveEvent(_ event: DocumentSaveCoordinator.SaveEvent) {
        switch event {
        case .dirty:
            saveState = .unsaved
            scheduleAutomaticSnapshotAfterEdit()
        case .saving:
            saveState = .saving
        case .saved:
            saveState = .saved
        case .failed:
            saveState = .failed
        }
    }

    func normalizedChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
    }

    func normalizedEpisodeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Episode.defaultTitle : trimmed
    }

    static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    func loadAttachments(for url: URL) async -> [Attachment] {
        do {
            return try await loadAttachmentsThrowing(for: url)
        } catch {
            print("[FUMINIWA] 資料一覧の読み込みに失敗しました(\(Self.errorCategory(error)))")
            return []
        }
    }

    func loadAttachmentsThrowing(for url: URL) async throws -> [Attachment] {
        guard let attachmentManager else { return [] }
        return try await attachmentManager.listAttachments(in: url)
    }

    func saveDocumentPackage(_ document: NovelDocument, to url: URL) async throws {
        try await repository.save(document, to: url)
    }

    /// D-061のremote/merge snapshotを、prepared Editor境界の中でpackageへ先に
    /// atomic保存してからmemoryへinstallする。同じdocument session以外へは適用しない。
    func persistAndInstallWorkSyncSnapshot(
        _ snapshot: WorkSnapshot,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared,
              documentSessionToken == expectedSession else { return false }
        let synchronizedDocument: NovelDocument
        do {
            synchronizedDocument = try snapshot.materializedDocument()
        } catch {
            return false
        }
        guard synchronizedDocument.id == expectedSession.documentID else { return false }
        do {
            return try await saveCoordinator.performExclusive {
                guard documentSessionToken == expectedSession,
                      documentURL.standardizedFileURL == expectedSession.documentURL else { return false }
                try deviceSyncRuntime?.setup?.validatePrivateWorkingCopy(documentURL)
                try await repository.save(synchronizedDocument, to: documentURL)
                try deviceSyncRuntime?.setup?.validatePrivateWorkingCopy(documentURL)
                let loadedDocument = try await repository.load(from: documentURL)
                try deviceSyncRuntime?.setup?.validatePrivateWorkingCopy(documentURL)
                guard documentSessionToken == expectedSession,
                      documentURL.standardizedFileURL == expectedSession.documentURL,
                      loadedDocument.id == expectedSession.documentID,
                      try WorkSnapshot(document: loadedDocument) == snapshot else { return false }
                guard await recordLocalLibraryPackageSave(loadedDocument, at: documentURL) else {
                    return false
                }

                let previousChapterID = selectedChapterID
                let previousEpisodeID = selectedEpisodeID
                let previousCharacterID = selectedCharacterID
                let previousPlotCardID = selectedPlotCardID
                let previousFlagID = selectedFlagID
                let previousWorldNoteID = selectedWorldNoteID
                // repositoryから読み戻してexact一致したinstanceだけをEditorへ入れる。
                document = loadedDocument
                noteDeviceSyncPackageSaved(loadedDocument)
                editorContentGeneration &+= 1

                if let previousChapterID,
                   let previousEpisodeID,
                   loadedDocument.chapters.contains(where: { chapter in
                       chapter.id == previousChapterID
                           && chapter.episodes.contains(where: { $0.id == previousEpisodeID })
                   }) {
                    selectedChapterID = previousChapterID
                    selectedEpisodeID = previousEpisodeID
                } else {
                    setInitialSelection(for: loadedDocument)
                }
                selectedCharacterID = previousCharacterID.flatMap { id in
                    loadedDocument.characters.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.characters.first?.id
                selectedPlotCardID = previousPlotCardID.flatMap { id in
                    loadedDocument.plotCards.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.plotCards.first?.id
                selectedFlagID = previousFlagID.flatMap { id in
                    loadedDocument.flags.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.flags.first?.id
                selectedWorldNoteID = previousWorldNoteID.flatMap { id in
                    loadedDocument.worldNotes.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.worldNotes.first?.id
                saveState = .saved
                return true
            }
        } catch {
            return false
        }
    }

    /// D-061のlocal recovery／conflict choice前に、現在のpackageを保存層から
    /// 読み戻してexact snapshotを得る。memory上の編集中値だけを根拠にremote版を
    /// materializeせず、atomic save済みの版だけをcoordinatorへ渡す。
    func readCurrentWorkSyncPackageSnapshotAtPreparedBoundary(
        expectedSession: DocumentSessionToken
    ) async -> WorkSnapshot? {
        guard editorCommandSession.isDocumentTransitionPrepared,
              documentSessionToken == expectedSession else { return nil }
        do {
            return try await saveCoordinator.performExclusive {
                guard documentSessionToken == expectedSession,
                      documentURL.standardizedFileURL == expectedSession.documentURL else { return nil }
                let loadedDocument = try await repository.load(from: documentURL)
                guard loadedDocument.id == expectedSession.documentID else { return nil }
                return try WorkSnapshot(document: loadedDocument)
            }
        } catch {
            return nil
        }
    }

    // MARK: - 既定の保存先

    static func defaultDirectory(fileManager: FileManager, directoryName: String) -> URL {
        #if DEBUG
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent("Drafts", isDirectory: true)
        }
        #endif
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func defaultSaveURL(
        forTitle title: String,
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        defaultDirectory(fileManager: fileManager, directoryName: directoryName)
            .appendingPathComponent("\(title).novelpkg", isDirectory: true)
    }

    /// 既定保存先の `<title>.novelpkg` を返す。
    /// 既に同名のパッケージが存在する場合は連番を振って重複を避ける。
    static func availableSaveURL(
        forTitle title: String,
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        let directory = defaultDirectory(fileManager: fileManager, directoryName: directoryName)

        var candidate = directory.appendingPathComponent("\(title).novelpkg", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(title)\(suffix).novelpkg", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
