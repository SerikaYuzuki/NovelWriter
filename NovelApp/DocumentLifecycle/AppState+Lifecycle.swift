import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    // MARK: - 作品ライフサイクル

    func performForCurrentDocument<T>(
        expectedSession: DocumentSessionToken? = nil,
        ifStale staleValue: T,
        operation: @MainActor () async -> T
    ) async -> T {
        guard !isTerminationPending else { return staleValue }
        let originSession = expectedSession ?? documentSessionToken
        return await documentOperationGate.perform {
            guard documentSessionToken == originSession else { return staleValue }
            return await operation()
        }
    }

    /// 確認ダイアログなど、`await`を持たないUI操作を元の作品だけへ適用する。
    /// Save Asを含む作品世代の変更後や終了処理開始後は、IDが同じでも拒否する。
    func permitsMutation(expectedSession: DocumentSessionToken?) -> Bool {
        DocumentLifecyclePermissionPolicy.permitsMutation(
            currentSession: documentSessionToken,
            expectedSession: expectedSession,
            isTerminationPending: isTerminationPending,
            isDocumentTransitionInProgress: isDocumentTransitionInProgress
        )
    }

    /// 表示中Editorが確定済み本文をモデルへ同期するための判定。
    ///
    /// 終了要求後は新しいUI操作を止める一方、既に表示中のIME marked textは
    /// 最終保存へ含める必要がある。固定sessionとの一致だけを確認し、終了処理中の
    /// `prepareForDocumentTransition()`から届く最後のcallbackは受け入れる。
    func permitsEditorSynchronization(expectedSession: DocumentSessionToken?) -> Bool {
        DocumentLifecyclePermissionPolicy.permitsEditorSynchronization(
            currentSession: documentSessionToken,
            expectedSession: expectedSession,
            isTerminationPending: isTerminationPending,
            isDocumentTransitionInProgress: isDocumentTransitionInProgress
        )
    }

    var permitsDocumentInteraction: Bool {
        !deviceSyncStartupFailedSafely &&
            startupState.isReady &&
            (!usesWholeWorkSyncRuntime || usesNoteSyncRuntime || !deviceSyncLocalRecoveryPending) &&
            (!isDocumentTransitionInProgress || permitsDeviceSyncSelectionMutationAfterFlush)
    }

    var permitsDocumentChoice: Bool {
        !deviceSyncStartupFailedSafely &&
            startupState.permitsDocumentChoice &&
            !isStartupLibraryOperationInProgress &&
            !isDocumentTransitionInProgress &&
            !isTerminationPending
    }

    var permitsReturnToCloudLibrary: Bool {
        deviceSyncRuntime?.library != nil && permitsDocumentInteraction
    }

    /// Workbenchの作品を端末へ確定してから、同じwindowでcloud shelfへ戻る。
    /// active package URLはUIへ渡さず、session generationを進めて旧View actionを無効化する。
    @discardableResult
    func returnToStartupLibrary(
        expectedSession: DocumentSessionToken? = nil,
        localFirst: Bool = false
    ) async -> Bool {
        guard deviceSyncRuntime?.library != nil else { return false }
        let returned = await performForCurrentDocument(
            expectedSession: expectedSession,
            ifStale: false
        ) {
            guard startupState.isReady, beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else {
                return false
            }

            advanceDocumentSession(document: document, url: documentURL)
            deviceSyncSelectionDidChange()
            startupLibraryRefreshGeneration &+= 1
            startupRemoteLibraryEntries = [:]
            permitsCloudLibraryMutation = false
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .offline,
                    isLoading: true
                )
            )
            return true
        }
        if returned {
            _ = await refreshLocalStartupLibrary()
            if localFirst {
                scheduleStartupLibraryRemoteRefreshIfNeeded()
            } else {
                await refreshStartupLibrary()
            }
        }
        return returned
    }

    /// provider待機でdocument operation gateを保持せず、開始／再検査時だけ現在作品を読むための条件。
    /// 終了要求後は`permitsDocumentInteraction`がtrueでも新しい長時間処理を開始しない。
    var permitsLongRunningDocumentOperation: Bool {
        !deviceSyncStartupFailedSafely &&
            startupState.isReady &&
            !isDocumentTransitionInProgress &&
            !isTerminationPending
    }

    /// TextField等のfirst responderとEditorKit本文を同じ同期区間で確定し、
    /// 次の保存・installが終わるまで旧Workbenchからの変更を閉じる。
    func beginDocumentTransition() -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        if let keyWindow = NSApp.keyWindow, !keyWindow.makeFirstResponder(nil) {
            return false
        }
        guard editorCommandSession.prepareForDocumentTransition() else { return false }
        isDocumentTransitionInProgress = true
        return true
    }

    func endDocumentTransition() {
        isDocumentTransitionInProgress = false
        editorCommandSession.resumeAfterDocumentTransition()
    }

    /// 現在の作品を失わず、指定 URL の作品へ切り替える。
    ///
    /// 読み込み結果は一時値に保持し、本文と資料一覧の両方を取得できた後で現在作品の
    /// 保留中保存を完了させる。保存または読み込みに失敗した場合は、現在の状態を
    /// 一切置き換えない。
    @discardableResult
    func openDocument(
        at url: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await openDocument(
            at: url,
            expectedSession: expectedSession,
            startupSource: .chosenDocument
        )
    }

    func openDocument(
        at url: URL,
        expectedSession: DocumentSessionToken?,
        startupSource: StartupDocumentSource
    ) async -> Bool {
        guard !deviceSyncStartupFailedSafely, !isTerminationPending else { return false }
        let preparesSelectedStartupDocument = switch startupState {
        case .documentSelection, .recovery:
            true
        case .loading, .ready:
            false
        }
        let opened = await documentOperationGate.perform {
            if let expectedSession, documentSessionToken != expectedSession {
                return false
            }
            return await openDocumentSerially(at: url, startupSource: startupSource)
        }
        if opened, preparesSelectedStartupDocument {
            // 通常起動のchooserはscene起動時のpreflight後に作品をinstallする。
            // Workbenchや保存セクションの表示有無へ依存せず、選択した作品自身を
            // activation直後にlocal journal復旧へ接続する(D-061 / D-062)。
            await prepareActiveDeviceSyncLocally()
        }
        return opened
    }

    /// Opening a locally verified package completes the foreground transition
    /// only after local journal recovery. The preparation lane schedules remote
    /// publication separately, so this never waits for CloudKit synchronization.
    func prepareActiveDeviceSyncLocally() async {
        guard startupState.isReady else { return }
        if usesWholeWorkSyncRuntime, let identity = currentWorkSyncPreparationIdentity {
            await prepareWholeWorkSync(for: identity)
        } else if let lookup = currentDeviceSyncLookupIdentity {
            await prepareDeviceSync(for: lookup)
        }
    }

    func scheduleActiveDeviceSyncPreparation() {
        Task { @MainActor [weak self] in
            await self?.refreshOrPrepareSelectedEpisodeDeviceSync()
        }
    }

    private func openDocumentSerially(
        at url: URL,
        startupSource: StartupDocumentSource
    ) async -> Bool {
        let targetURL = url.standardizedFileURL
        let hadReadyDocument = startupState.isReady
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        guard !hadReadyDocument || targetURL != documentURL.standardizedFileURL else {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            return await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: false,
                waitForRemote: false
            )
        }
        if !hadReadyDocument {
            startupState = .loading
        }

        let loadedDocument: NovelDocument
        let loadedAttachments: [Attachment]
        do {
            loadedDocument = try await repository.load(from: targetURL)
            loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
        } catch {
            print("[FUMINIWA] 作品の読み込みに失敗しました(\(Self.errorCategory(error)))")
            if !hadReadyDocument {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .cannotOpenDocument,
                        source: startupSource,
                        documentURL: targetURL
                    )
                )
            }
            return false
        }

        // 読み込み待ちの間に現在作品が編集されても、ここで全入力を確定・停止し、
        // 最新revisionを保存してから切り替える。
        if hadReadyDocument {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else { return false }
        }

        installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        return true
    }

    /// 新規作品を既定保存先へ作成し、保存成功後にだけ現在作品として採用する。
    @discardableResult
    func createNewDocument(expectedSession: DocumentSessionToken? = nil) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        if deviceSyncRuntime?.library != nil {
            guard permitsCloudLibraryMutation,
                  !isStartupLibraryOperationInProgress else { return false }
            isStartupLibraryOperationInProgress = true
            defer { isStartupLibraryOperationInProgress = false }
            let publication = await performForCurrentDocument(
                expectedSession: expectedSession,
                ifStale: PendingPrivateLibraryPublication?.none
            ) {
                await createPrivateLibraryWorkSerially(
                    NovelDocument.newDocument(),
                    portableSourceURL: nil,
                    portableRepository: nil
                )
            }
            if let publication {
                schedulePrivateLibraryPublish(publication)
                scheduleActiveDeviceSyncPreparation()
            }
            return publication != nil
        }
        let preparesSelectedStartupDocument = switch startupState {
        case .documentSelection, .recovery:
            true
        case .loading, .ready:
            false
        }
        let created = await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await createNewDocumentSerially()
        }
        if created, preparesSelectedStartupDocument {
            await prepareActiveDeviceSyncLocally()
        }
        return created
    }

    func createPrivateLibraryWorkSerially(
        _ requestedDocument: NovelDocument,
        portableSourceURL: URL?,
        portableRepository: (any PortableDocumentPackageRepository)?,
        activate: Bool = true
    ) async -> PendingPrivateLibraryPublication? {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              let validatedRepository = repository as? PortableDocumentPackageRepository,
              permitsCloudLibraryMutation else { return nil }
        let hadReadyDocument = startupState.isReady
        let workID = SyncWorkID()
        var stagingURL: URL?
        var didReserve = false
        var didAttestStaging = false
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        do {
            let expectedAttestation = try DeviceSyncLocalPackageAttestation(
                document: requestedDocument,
                updatedAt: runtime.now()
            )
            try await library.reserveForPublish(workID, expectedAttestation)
            didReserve = true
            let staging = try await library.stagingPackageURL(workID)
            stagingURL = staging
            if let portableSourceURL, let portableRepository {
                let finalURL = try await library.packageURL(workID)
                guard !DocumentURLPolicy.urlsOverlap(portableSourceURL, staging),
                      !DocumentURLPolicy.urlsOverlap(portableSourceURL, finalURL) else {
                    throw DeviceSyncLocalLibraryError.packageMismatch
                }
                let validated = try await portableRepository.validatePortablePackage(
                    at: portableSourceURL
                )
                guard validated == requestedDocument else {
                    throw DeviceSyncLocalLibraryError.packageMismatch
                }
                try await portableRepository.saveValidatedCopy(
                    requestedDocument,
                    from: portableSourceURL,
                    to: staging
                )
            } else {
                try await repository.save(requestedDocument, to: staging)
            }

            try await library.validateStagingPackage(staging, workID)
            let stagedReadback = try await validatedRepository.validatePortablePackage(at: staging)
            guard stagedReadback == requestedDocument,
                  try WorkSnapshot(document: stagedReadback) == WorkSnapshot(document: requestedDocument) else {
                throw DeviceSyncLocalLibraryError.packageMismatch
            }
            let attestation = try DeviceSyncLocalPackageAttestation(
                document: stagedReadback,
                updatedAt: expectedAttestation.updatedAt
            )
            guard attestation == expectedAttestation else {
                throw DeviceSyncLocalLibraryError.packageMismatch
            }
            try await library.attestPublishStaging(workID, attestation)
            didAttestStaging = true

            let finalURL = try await library.installStagingPackage(staging, workID)
            stagingURL = nil
            try await library.validateInstalledPackage(workID)
            let finalReadback = try await validatedRepository.validatePortablePackage(at: finalURL)
            let finalAttestation = try DeviceSyncLocalPackageAttestation(
                document: finalReadback,
                updatedAt: attestation.updatedAt
            )
            guard finalReadback == requestedDocument,
                  finalAttestation == attestation else {
                throw DeviceSyncLocalLibraryError.packageMismatch
            }
            try await library.confirmPublishPackage(workID, attestation)

            if activate {
                if hadReadyDocument {
                    guard beginDocumentTransition() else { return nil }
                    didBeginTransition = true
                    guard await flushPreparedDeviceSyncBoundarySerially(
                        releaseAuthority: true,
                        waitForRemote: false
                    ) else {
                        return nil
                    }
                }
                let loadedAttachments = try await loadAttachmentsThrowing(for: finalURL)
                isCurrentWorkBoundToCloud = false
                installDocument(finalReadback, at: finalURL, attachments: loadedAttachments)
                guard startupState.isReady else { return nil }
            }
            return PendingPrivateLibraryPublication(
                workID: workID,
                document: finalReadback,
                packageURL: finalURL,
                mayAttemptInitialPublish: mayAttemptInitialCloudPublish
            )
        } catch {
            if let stagingURL, !didAttestStaging {
                try? await library.discardStagingPackage(stagingURL, workID)
            }
            if didReserve, !didAttestStaging {
                try? await library.abortPublishReservation(workID)
            }
            return nil
        }
    }

    /// Package/registryと旧作品の最終保存、新作品activationが完了した後だけ
    /// account-scoped createを試す。通信失敗時はlocalPendingを残し、作品切替を
    /// 巻き戻さない。
    func schedulePrivateLibraryPublish(
        _ publication: PendingPrivateLibraryPublication
    ) {
        guard publication.mayAttemptInitialPublish else { return }
        guard pendingLibraryPublishTasks[publication.workID] == nil else { return }
        let task = Task { [weak self] in
            guard let self, let library = deviceSyncRuntime?.library else { return }
            try? await library.publishNewWork(
                publication.workID,
                publication.document,
                publication.packageURL
            )
            pendingLibraryPublishTasks[publication.workID] = nil
            if startupState.isReady,
               documentURL.standardizedFileURL == publication.packageURL.standardizedFileURL {
                scheduleActiveDeviceSyncPreparation()
            } else if case let .documentSelection(context) = startupState,
                      context.presentation == .cloudLibrary {
                scheduleStartupLibraryRemoteRefreshIfNeeded()
            }
        }
        pendingLibraryPublishTasks[publication.workID] = task
    }

    /// Error descriptions may embed full private paths. Console gets only a stable
    /// operation-local category; UI presents a separate path-free message.
    static func errorCategory(_ error: any Error) -> String {
        String(reflecting: type(of: error))
    }

    func portableDocumentRepository() -> (any PortableDocumentPackageRepository)? {
        repository as? PortableDocumentPackageRepository
    }

    private func createNewDocumentSerially() async -> Bool {
        let hadReadyDocument = startupState.isReady
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }
        let previousRecoveryContext: StartupRecoveryContext? = if case let .recovery(context) = startupState {
            context
        } else {
            nil
        }

        if !hadReadyDocument {
            startupState = .loading
        }

        let newDocument = NovelDocument.newDocument()
        let newURL = Self.availableSaveURL(
            forTitle: newDocument.title,
            fileManager: fileManager,
            directoryName: defaultDocumentDirectoryName
        )
        let newAttachments: [Attachment]

        do {
            try await repository.save(newDocument, to: newURL)
            newAttachments = try await loadAttachmentsThrowing(for: newURL)
        } catch {
            print("[FUMINIWA] 新規作品の保存に失敗しました(\(Self.errorCategory(error)))")
            if !hadReadyDocument {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .cannotCreateDocument,
                        source: .initialDocument,
                        documentURL: newURL
                    )
                )
            } else if let previousRecoveryContext {
                startupState = .recovery(previousRecoveryContext)
            }
            return false
        }

        // 新規作品の書き込み中にも現在作品は編集できる。切り替え直前に全入力を
        // 確定・停止し、最新revisionを現在の保存先へ確実に残す。
        if hadReadyDocument {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else { return false }
        }

        installDocument(newDocument, at: newURL, attachments: newAttachments)
        return true
    }

    /// 現在作品を別 URL へ複製し、成功後にだけ保存先を切り替える。
    ///
    /// `DocumentCopyingRepository` が利用できる場合は、モデル外の資料・
    /// スナップショット・未知項目も保存層に引き継がせる。コピー中に生じた編集は
    /// dirty revision として残り、保存先切り替え後に新 URL へ保存される。
    @discardableResult
    func saveDocument(as url: URL, expectedSession: DocumentSessionToken? = nil) async -> Bool {
        await saveDocumentResult(as: url, expectedSession: expectedSession) == .saved
    }

    /// Presenterが非同期完了後の可変状態から失敗理由を推測しないための結果付き経路。
    func saveDocumentResult(
        as url: URL,
        expectedSession: DocumentSessionToken? = nil,
        preAdoptionValidation: (@Sendable (URL) throws -> Void)? = nil
    ) async -> SaveDocumentAsResult {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: .staleSession) {
            await saveDocumentSerially(
                as: url,
                preAdoptionValidation: preAdoptionValidation
            )
        }
    }

    private func saveDocumentSerially(
        as url: URL,
        preAdoptionValidation: (@Sendable (URL) throws -> Void)? = nil
    ) async -> SaveDocumentAsResult {
        guard startupState.isReady else { return .failedBeforeSwitch }
        let destinationURL = url.standardizedFileURL
        let sourceURL = documentURL

        guard destinationURL != sourceURL.standardizedFileURL else {
            return await saveCoordinator.saveNow() ? .saved : .failedBeforeSwitch
        }

        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        guard beginDocumentTransition() else { return .failedBeforeSwitch }
        didBeginTransition = true
        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        ) else {
            return .failedBeforeSwitch
        }
        // Device Sync の旧話authorityはcopy開始前に安全に閉じる。一方、通常の
        // local-only作品では大きなpackage copy中も執筆を止めないため、ここで
        // Editorを一度再開し、保存先を採用する直前にもう一度確定する。
        endDocumentTransition()
        didBeginTransition = false

        do {
            let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                let documentSnapshot = document
                if let copyingRepository = repository as? DocumentCopyingRepository {
                    try await copyingRepository.saveCopy(
                        documentSnapshot,
                        from: sourceURL,
                        to: destinationURL
                    )
                } else {
                    try await repository.save(documentSnapshot, to: destinationURL)
                }
                try preAdoptionValidation?(destinationURL)

                // copy中に増えたlocal-only編集を旧sessionへ確定したうえで、
                // URL・recent・session世代を一つの保存排他区間内で切り替える。
                guard beginDocumentTransition() else { return false }
                didBeginTransition = true
                // URL・recent・session世代の切替までを保存排他区間に含める。
                // コピー中に待機した通常保存が、旧URLへ再開する隙間を作らない。
                documentURL = destinationURL
                rememberDocumentURL(destinationURL)
                advanceDocumentSession(document: document, url: destinationURL)
                deviceSyncSelectionDidChange()
                return true
            }

            switch result {
            case .saveFailedBeforeOperation:
                return .failedBeforeSwitch
            case let .completed(didSwitch, savedAfterOperation):
                guard didSwitch else { return .failedBeforeSwitch }
                return savedAfterOperation ? .saved : .switchedButLatestEditsFailed
            }
        } catch {
            print("[FUMINIWA] 別名保存に失敗しました(\(Self.errorCategory(error)))")
            return .failedBeforeSwitch
        }
    }

    /// 現在のapp-private作業コピーを、利用者が選んだportable `.novelpkg`へ
    /// 複製する。書き出し先を現在作品として採用せず、recent URL、document
    /// session、Device Sync bindingも変更しない。
    func exportDocumentPackage(
        to url: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async throws {
        let exported = await performForCurrentDocument(
            expectedSession: expectedSession,
            ifStale: false
        ) {
            await exportDocumentPackageSerially(to: url)
        }
        guard exported else { throw PackageExportError.staleSession }
    }

    private func exportDocumentPackageSerially(to url: URL) async -> Bool {
        guard startupState.isReady else { return false }
        let destinationURL = url.standardizedFileURL
        let sourceURL = documentURL.standardizedFileURL
        guard !DocumentURLPolicy.urlsOverlap(destinationURL, sourceURL) else { return false }

        guard beginDocumentTransition() else { return false }
        defer { endDocumentTransition() }

        // native editor / forms → app-private package → Work journalを確定してから
        // その値を複製する。remote処理やactive URLの切替は行わない。
        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: false,
            waitForRemote: false
        ) else {
            return false
        }

        do {
            let documentSnapshot = document
            guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                throw PackageExportError.unavailable
            }
            try await portableRepository.saveValidatedCopy(
                documentSnapshot,
                from: sourceURL,
                to: destinationURL
            )
            let readBack = try await portableRepository.validatePortablePackage(at: destinationURL)
            guard readBack == documentSnapshot else {
                throw PackageExportError.saveFailed
            }
            return true
        } catch {
            print("[FUMINIWA] 作品パッケージの書き出しに失敗しました(\(Self.errorCategory(error)))")
            return false
        }
    }

    func installDocument(
        _ newDocument: NovelDocument,
        at url: URL,
        attachments newAttachments: [Attachment]
    ) {
        guard !deviceSyncStartupFailedSafely else { return }
        document = newDocument
        documentURL = url
        noteDeviceSyncPackageSaved(newDocument)
        advanceDocumentSession(document: newDocument, url: url)
        editorContentGeneration &+= 1
        setInitialSelection(for: newDocument)
        deviceSyncSelectionDidChange()
        selectedCharacterID = newDocument.characters.first?.id
        selectedPlotCardID = newDocument.plotCards.first?.id
        selectedFlagID = newDocument.flags.first?.id
        attachments = newAttachments
        saveState = .saved
        startupState = .ready
        rememberDocumentURL(url)
        cancelAutomaticSnapshotScheduling()
        lastAutomaticSnapshotRevision = saveCoordinator.lastSavedRevision
    }

    func advanceDocumentSession(document: NovelDocument, url: URL) {
        documentSessionToken = DocumentSessionToken(
            generation: documentSessionToken.generation &+ 1,
            documentID: document.id,
            documentURL: url.standardizedFileURL
        )
    }

    func setInitialSelection(for newDocument: NovelDocument) {
        lastSelectedEpisodeByChapter = [:]
        let chapterID = newDocument.chapters.first?.id
        let episodeID = newDocument.chapters.first?.episodes.first?.id
        setSelection(chapterID: chapterID, episodeID: episodeID)
        selectedWorldNoteID = newDocument.worldNotes.first?.id
        plotOutlineSelection = chapterID.map(PlotOutlineSelection.chapter) ?? .unassigned
    }

    func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        let didChange = selectedChapterID != chapterID || selectedEpisodeID != episodeID
        guard !didChange || permitsSynchronousDeviceSyncSelectionMutation else { return }
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        if let chapterID, let episodeID {
            lastSelectedEpisodeByChapter[chapterID] = episodeID
        }
        if let chapterID {
            plotOutlineSelection = .chapter(chapterID)
        }
        workspaceSelection.outlineItemID = chapterID.map { OutlineItemID(rawValue: $0.rawValue.uuidString) }
        if didChange {
            deviceSyncSelectionDidChange()
        }
    }

    var permitsSynchronousDeviceSyncSelectionMutation: Bool {
        if usesWholeWorkSyncRuntime, !usesNoteSyncRuntime, deviceSyncLocalRecoveryPending {
            return false
        }
        return deviceSyncRuntime == nil ||
            activeDeviceSyncIdentity == nil ||
            permitsDeviceSyncSelectionMutationAfterFlush ||
            editorCommandSession.isDocumentTransitionPrepared
    }

    func preferredEpisodeID(in chapterID: ChapterID) -> EpisodeID? {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return nil }
        if let remembered = lastSelectedEpisodeByChapter[chapterID], chapter.episodes.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return chapter.episodes.first?.id
    }

    func observeResignActive() {
        guard resignActiveObserver.value == nil else { return }
        resignActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDeviceSyncForBackground(waitForRemote: false)
                await self?.captureAutomaticSnapshotForBackground()
            }
        }
    }

    func observeSystemSleep() {
        guard systemSleepObserver.value == nil else { return }
        systemSleepObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDeviceSyncForBackground(waitForRemote: false)
                await self?.captureAutomaticSnapshotForBackground()
            }
        }
    }

    func observeDeviceSyncReactivation() {
        guard becomeActiveObserver.value == nil, systemWakeObserver.value == nil else { return }
        becomeActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceSyncReactivation()
            }
        }
        systemWakeObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceSyncReactivation()
            }
        }
    }

    /// AppKit activation notifications are signals only. The notification
    /// callback schedules remote work and returns without awaiting CloudKit.
    private func scheduleDeviceSyncReactivation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case let .documentSelection(context) = startupState,
               context.presentation == .cloudLibrary {
                await refreshStartupLibrary()
            } else {
                await retryAccountScopedPendingPublicationsInBackground()
                await refreshActiveDeviceSyncWithoutPreparing()
            }
        }
    }

    private func rememberDocumentURL(_ url: URL) {
        guard deviceSyncRuntime?.library == nil else { return }
        userDefaults.set(url.path, forKey: Self.recentDocumentPathKey)
    }
}
