import EditorKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
import NovelSyncTesting
import Testing

@MainActor
@Suite("Device Sync app integration", .serialized)
struct DeviceSyncAppIntegrationTests {
    @Test("離れた日本語編集は自動統合した確認用下書きになる")
    func disjointJapaneseConflictCreatesAutomaticDraft() throws {
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
        let base = try revision(
            key: key,
            parents: [],
            content: "吾輩は猫である。名前はまだない。"
        )
        let local = try revision(
            key: key,
            parents: [base.revisionID],
            content: "吾輩は黒猫である。名前はまだない。"
        )
        let remote = try revision(
            key: key,
            parents: [base.revisionID],
            content: "吾輩は猫である。名前はまだ無い。"
        )

        let draft = DeviceSyncConflictDraft(
            conflict: EpisodeConflict(base: base, local: local, remote: remote)
        )

        #expect(draft.kind == .automaticIntegration)
        #expect(draft.content == "吾輩は黒猫である。名前はまだ無い。")
        #expect(draft.title == "自動統合の下書き")
    }

    @Test("作品同期はオフライン編集をpackageとjournalへ残し再起動後に送れる")
    func wholeWorkSyncRecoversOfflineEditAfterRestart() async throws {
        let fixture = makeFixture(content: "地下鉄で編集する本文")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workJournal = InMemoryWorkSyncJournal()
        let workServer = InMemoryWorkSyncServer()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            workTransport: workServer,
            binding: { _, _ in resolution }
        )

        let first = makeState(repository: repository, runtime: runtime)
        #expect(await first.openDocument(at: fixture.url))
        let firstLookup = try #require(first.currentDeviceSyncLookupIdentity)
        await first.prepareDeviceSync(for: firstLookup)
        await waitForWorkSyncNetwork(first)
        #expect(await workServer.currentHead(for: workID) != nil)

        await workServer.setOnline(false)
        first.updateDocumentTitle("通信なしで変更した作品名")
        #expect(await first.saveNow())
        await waitForWorkSyncNetwork(first)

        let durablePackage = try await repository.load(from: fixture.url)
        let durableJournal = try #require(await workJournal.storedRecord(for: workID))
        #expect(durablePackage.title == "通信なしで変更した作品名")
        #expect(durableJournal.localHead.snapshot.title == "通信なしで変更した作品名")
        #expect(first.deviceSyncState == .offlineLocal)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: fixture.url))
        let relaunchedLookup = try #require(relaunched.currentDeviceSyncLookupIdentity)
        await relaunched.prepareDeviceSync(for: relaunchedLookup)
        #expect(relaunched.document.title == "通信なしで変更した作品名")
        #expect(relaunched.deviceSyncLocalRecoveryPending == false)

        await workServer.setOnline(true)
        await relaunched.refreshWholeWorkSync()
        await waitForWorkSyncNetwork(relaunched)
        #expect(await workServer.currentHead(for: workID)?.snapshot.title == "通信なしで変更した作品名")
        #expect(relaunched.deviceSyncTransferState == .upToDate)
    }

    @Test("作品package書き出しはactive identityとjournalを変えず付随dataを保持する")
    func packageExportPreservesActiveIdentityJournalAndResources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-Package-Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = NovelpkgRepository()
        let sourceURL = directory.appendingPathComponent("Active.novelpkg", isDirectory: true)
        let destinationURL = directory.appendingPathComponent("Export.novelpkg", isDirectory: true)
        let attachmentSource = directory.appendingPathComponent("資料.txt")
        let futureResourceURL = sourceURL.appendingPathComponent("future-resource.bin")
        let document = NovelDocument(
            title: "identityを保つ作品",
            chapters: [Chapter(title: "第一章", episodes: [Episode(content: "本文")])]
        )
        try await repository.save(document, to: sourceURL)
        try Data("資料本文".utf8).write(to: attachmentSource)
        _ = try await repository.addAttachment(from: attachmentSource, to: sourceURL)
        _ = try await repository.saveSnapshot(document, to: sourceURL)
        try Data([0x00, 0x7F, 0xFF]).write(to: futureResourceURL)

        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workJournal = InMemoryWorkSyncJournal()
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            workTransport: InMemoryWorkSyncServer(),
            binding: { _, _ in resolution }
        )
        let defaultsName = "FUMINIWA.PackageExportIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                deviceSyncRuntime: runtime
            ),
            initialStartupState: .ready
        )

        #expect(await state.openDocument(at: sourceURL))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await waitForWorkSyncNetwork(state)

        let originalSession = state.documentSessionToken
        let originalURL = state.documentURL
        let originalRecent = defaults.string(forKey: AppPreferenceKey.recentDocumentPath)
        let originalIdentity = try #require(state.activeWorkSyncIdentity)
        let originalJournal = try #require(await workJournal.storedRecord(for: workID))
        let originalChapterID = state.selectedChapterID
        let originalEpisodeID = state.selectedEpisodeID
        let originalWorkspaceSelection = state.workspaceSelection

        try await state.exportDocumentPackage(
            to: destinationURL,
            expectedSession: originalSession
        )

        #expect(state.documentSessionToken == originalSession)
        #expect(state.documentURL == originalURL)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == originalRecent)
        #expect(state.activeWorkSyncIdentity == originalIdentity)
        #expect(state.activeWorkSyncIdentity?.workID == workID)
        #expect(await workJournal.storedRecord(for: workID) == originalJournal)
        #expect(state.selectedChapterID == originalChapterID)
        #expect(state.selectedEpisodeID == originalEpisodeID)
        #expect(state.workspaceSelection == originalWorkspaceSelection)
        #expect(try await repository.validatePortablePackage(at: destinationURL) == document)
        #expect(try await repository.listAttachments(in: destinationURL).map(\.fileName) == ["資料.txt"])
        #expect(try await repository.listSnapshots(in: destinationURL).count == 1)
        #expect(FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("future-resource.bin").path
        ))
    }

    @Test("作品保存はjournal stage→package→journal confirmの後にnetworkへ渡す")
    func wholeWorkSaveOrdersJournalPackageConfirmationBeforeNetwork() async throws {
        let fixture = makeFixture(content: "保存順を確認する本文")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let trace = WorkSyncEventTrace()
        let workID = SyncWorkID()
        let workJournal = TracingWorkSyncJournal(trace: trace)
        let workTransport = TracingWorkSyncTransport(trace: trace)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                workTransport: workTransport,
                binding: { _, _ in resolution }
            )
        )

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await waitForWorkSyncNetwork(state)
        await trace.reset()
        await repository.setSaveObserver { _ in
            await trace.record(.packageSave)
        }

        state.updateDocumentTitle("順序を守って保存した作品名")
        #expect(await state.saveNow())
        await waitForWorkSyncNetwork(state)

        let events = await trace.snapshot()
        let stageIndex = try #require(events.firstIndex(of: .journalStage))
        let packageIndex = try #require(events.firstIndex(of: .packageSave))
        let confirmationIndex = try #require(events.firstIndex(of: .journalConfirmation))
        let networkIndex = try #require(events.firstIndex(of: .network))
        #expect(stageIndex < packageIndex)
        #expect(packageIndex < confirmationIndex)
        #expect(confirmationIndex < networkIndex)
        #expect(await workTransport.currentHead(for: workID)?.snapshot.title
            == "順序を守って保存した作品名")
    }

    @Test("作品同期journal失敗でもpackage保存成功を端末保存失敗と表示しない")
    func wholeWorkJournalStageFailureKeepsPackageAndReportsSyncRetry() async throws {
        let fixture = makeFixture(content: "端末に残す本文")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workJournal = FailingWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .temporarilyOffline
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            workTransport: transport,
            binding: { _, _ in resolution }
        )
        let state = makeState(repository: repository, runtime: runtime)

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await state.workSyncRemoteBindingTask?.value
        await workJournal.failNextSave()

        state.updateDocumentTitle("journalが失敗しても残る作品名")
        #expect(await state.saveNow())

        let saved = try await repository.load(from: fixture.url)
        #expect(saved.title == "journalが失敗しても残る作品名")
        #expect(state.saveState == .saved)
        #expect(state.deviceSyncLocalDurabilityState == .savedSyncPreparationFailed)
        let status = DeviceSyncEditorStatusKind.resolve(
            saveState: state.saveState,
            syncState: state.deviceSyncState,
            transferState: state.deviceSyncTransferState,
            localDurability: state.deviceSyncLocalDurabilityState
        )
        #expect(status == .syncPreparationError)
        #expect(status.accessibilityLabel == "この端末に保存済み、同期準備を再試行")
        #expect(status.detail.contains("変更内容はこの端末に保存されています"))
        #expect(await transport.operationCount() == 0)
    }

    @Test("作品版の保存後読み戻しが不一致なら復旧choiceを確定しない")
    func corruptPackageReadbackCannotAcknowledgeWorkRecoveryChoice() async throws {
        let fixture = makeFixture(content: "本文")
        var baseDocument = fixture.document
        baseDocument.title = "前回確定版"
        var stagedDocument = fixture.document
        stagedDocument.title = "端末内の保存版"
        var observedDocument = fixture.document
        observedDocument.title = "現在の原稿"
        var corruptDocument = fixture.document
        corruptDocument.title = "壊れた読み戻し"

        let repository = DeviceSyncAppRepository()
        await repository.seed(observedDocument, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let coordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        _ = try await coordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: baseDocument),
            at: Date(timeIntervalSince1970: 1)
        )
        let staged = try await coordinator.stageLocalSnapshot(
            WorkSnapshot(document: stagedDocument),
            at: Date(timeIntervalSince1970: 2)
        )
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: Set(observedDocument.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .temporarilyOffline
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: transport,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await state.workSyncRemoteBindingTask?.value
        let review = try #require(state.workSyncLocalRecoveryReview)
        #expect(review.stagedLocalRevision?.revisionID == staged.revisionID)

        await repository.corruptNextSave(with: corruptDocument)
        await state.resolveWorkSyncLocalRecovery(
            using: .keepRemote,
            expectedReview: review,
            expectedSession: state.documentSessionToken
        )

        let retained = try #require(await journal.storedRecord(for: workID))
        #expect(retained.stagedLocalRevision?.revisionID == staged.revisionID)
        #expect(state.workSyncLocalRecoveryReview == review)
        #expect(state.deviceSyncLocalRecoveryPending)
        #expect(state.document.title == "現在の原稿")
        #expect(state.deviceSyncLocalDurabilityState == .failed)
        #expect(await transport.operationCount() == 0)
    }

    @Test("再起動時に残ったpackageとstaged版を比較してstaged版を復旧できる")
    func wholeWorkRestartRecoveryChoiceMaterializesStagedRevision() async throws {
        let fixture = makeFixture(content: "本文")
        var baseDocument = fixture.document
        baseDocument.title = "前回確定版"
        var stagedDocument = fixture.document
        stagedDocument.title = "保存途中の端末版"
        var observedDocument = fixture.document
        observedDocument.title = "現在のpackage版"
        let repository = DeviceSyncAppRepository()
        await repository.seed(observedDocument, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let coordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        _ = try await coordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: baseDocument),
            at: Date(timeIntervalSince1970: 1)
        )
        let staged = try await coordinator.stageLocalSnapshot(
            WorkSnapshot(document: stagedDocument),
            at: Date(timeIntervalSince1970: 2)
        )
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: Set(observedDocument.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .temporarilyOffline
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: transport,
                binding: { _, _ in resolution }
            )
        )

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await state.workSyncRemoteBindingTask?.value
        let review = try #require(state.workSyncLocalRecoveryReview)
        let presentation = WorkConflictPresentationAdapter.make(localRecovery: review)
        #expect(presentation.canChooseRemote)
        #expect(presentation.canChooseProposed == false)
        #expect(state.deviceSyncLocalRecoveryPending)

        await state.resolveWorkSyncLocalRecovery(
            using: .keepRemote,
            expectedReview: review,
            expectedSession: state.documentSessionToken
        )

        let saved = try await repository.load(from: fixture.url)
        let recovered = try #require(await journal.storedRecord(for: workID))
        #expect(saved.title == "保存途中の端末版")
        #expect(recovered.localHead.revisionID == staged.revisionID)
        #expect(recovered.stagedLocalRevision == nil)
        #expect(state.workSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(await transport.operationCount() == 0)
    }

    @Test("選んだ起動作品はEditor表示に依存せず作品journalへ接続する")
    func startupSelectionPreflightsWholeWorkWithoutWritingSection() async throws {
        let fixture = makeFixture(content: "起動作品の本文")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            remoteAvailability: .temporarilyOffline
        )
        let suiteName = "FUMINIWA.StartupSelectionPreflightTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(fixture.url.path, forKey: AppPreferenceKey.recentDocumentPath)
        defaults.set(ProjectSection.projectInfo.rawValue, forKey: AppPreferenceKey.projectSection)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                deviceSyncRuntime: DeviceSyncRuntime(
                    replicaID: replicaID,
                    transport: InMemoryEpisodeSyncServer(),
                    workTransport: transport,
                    binding: { _, _ in resolution }
                )
            )
        )

        await state.bootstrap()
        #expect(state.workspaceSelection.section == .projectInfo)
        #expect(await state.openRecentDocument(expectedSession: state.documentSessionToken))

        let durable = try #require(await journal.storedRecord(for: workID))
        #expect(state.startupState == .ready)
        #expect(state.workSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.permitsDocumentInteraction)
        let expectedSnapshot = try WorkSnapshot(document: fixture.document)
        #expect(durable.localHead.snapshot == expectedSnapshot)
        #expect(await transport.operationCount() == 0)
    }

    @Test("起動作品の選択直後はEditor表示に依存せず端末内復旧を完了する")
    func startupSelectionPreflightsWholeWorkRecoveryOutsideWritingSection() async throws {
        let fixture = makeFixture(content: "本文")
        var baseDocument = fixture.document
        baseDocument.title = "前回確定版"
        var stagedDocument = fixture.document
        stagedDocument.title = "保存途中の端末版"
        var observedDocument = fixture.document
        observedDocument.title = "現在のpackage版"
        let repository = DeviceSyncAppRepository()
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let coordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        _ = try await coordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: baseDocument),
            at: Date(timeIntervalSince1970: 1)
        )
        _ = try await coordinator.stageLocalSnapshot(
            WorkSnapshot(document: stagedDocument),
            at: Date(timeIntervalSince1970: 2)
        )
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: Set(observedDocument.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .temporarilyOffline
        )
        let suiteName = "FUMINIWA.StartupSelectionWorkSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(fixture.url.path, forKey: AppPreferenceKey.recentDocumentPath)
        defaults.set(ProjectSection.projectInfo.rawValue, forKey: AppPreferenceKey.projectSection)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                deviceSyncRuntime: DeviceSyncRuntime(
                    replicaID: replicaID,
                    transport: InMemoryEpisodeSyncServer(),
                    workTransport: transport,
                    binding: { _, _ in resolution }
                )
            )
        )

        await state.bootstrap()
        guard case .documentSelection = state.startupState else {
            Issue.record("作品選択画面へ移行しませんでした")
            return
        }
        #expect(state.workspaceSelection.section == .projectInfo)
        #expect(await state.openRecentDocument(expectedSession: state.documentSessionToken) == false)
        guard case .recovery = state.startupState else {
            Issue.record("読込失敗後にRecoveryへ移行しませんでした")
            return
        }
        await repository.seed(observedDocument, at: fixture.url)

        await state.retryStartup()

        let review = try #require(state.workSyncLocalRecoveryReview)
        #expect(state.startupState == .ready)
        #expect(state.deviceSyncLocalRecoveryPending)
        #expect(state.permitsDocumentInteraction == false)
        #expect(await transport.operationCount() == 0)

        await state.resolveWorkSyncLocalRecovery(
            using: .keepRemote,
            expectedReview: review,
            expectedSession: state.documentSessionToken
        )

        #expect(state.workSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.permitsDocumentInteraction)
        #expect(state.document.title == "保存途中の端末版")
        #expect(await transport.operationCount() == 0)
    }

    @Test("話がない起動作品も同期lookup待ちでWorkbenchを永久停止しない")
    func startupSelectionWithoutEpisodesKeepsLocalPackageEditable() async throws {
        let document = NovelDocument(
            title: "構成前の作品",
            chapters: [Chapter(title: "第一章", episodes: [])]
        )
        let url = packageURL("startup-selection-without-episodes")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let transport = CountingWorkSyncTransport()
        let suiteName = "FUMINIWA.EmptyStartupSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                deviceSyncRuntime: DeviceSyncRuntime(
                    replicaID: SyncReplicaID(),
                    transport: InMemoryEpisodeSyncServer(),
                    workTransport: transport,
                    binding: { _, _ in nil }
                )
            )
        )

        await state.bootstrap()
        #expect(await state.openRecentDocument(expectedSession: state.documentSessionToken))

        #expect(state.startupState == .ready)
        #expect(state.currentDeviceSyncLookupIdentity == nil)
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.permitsDocumentInteraction)
        #expect(state.document == document)
        #expect(await transport.operationCount() == 0)
    }

    @Test("話がない起動作品も編集解放前に作品journalを復旧する")
    func startupSelectionWithoutEpisodesRestoresBoundWorkJournalBeforeEditing() async throws {
        var baseDocument = NovelDocument(
            title: "前回確定版",
            chapters: [Chapter(title: "第一章", episodes: [])]
        )
        baseDocument.characters = [Character(name: "基準人物")]
        var stagedDocument = baseDocument
        stagedDocument.title = "保存途中の端末版"
        stagedDocument.characters = [Character(name: "保存途中の人物")]
        var observedDocument = baseDocument
        observedDocument.title = "現在のpackage版"
        observedDocument.characters = [Character(name: "現在の人物")]

        let url = packageURL("startup-selection-without-episodes-recovery")
        let repository = DeviceSyncAppRepository()
        await repository.seed(observedDocument, at: url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let coordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        _ = try await coordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: baseDocument),
            at: Date(timeIntervalSince1970: 1)
        )
        _ = try await coordinator.stageLocalSnapshot(
            WorkSnapshot(document: stagedDocument),
            at: Date(timeIntervalSince1970: 2)
        )
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: [],
            remoteAvailability: .temporarilyOffline
        )
        let suiteName = "FUMINIWA.EmptyBoundStartupSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        defaults.set(ProjectSection.projectInfo.rawValue, forKey: AppPreferenceKey.projectSection)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                deviceSyncRuntime: DeviceSyncRuntime(
                    replicaID: replicaID,
                    transport: InMemoryEpisodeSyncServer(),
                    workTransport: transport,
                    binding: { _, _ in resolution }
                )
            )
        )

        await state.bootstrap()
        #expect(await state.openRecentDocument(expectedSession: state.documentSessionToken))

        let review = try #require(state.workSyncLocalRecoveryReview)
        #expect(state.currentDeviceSyncLookupIdentity == nil)
        #expect(state.deviceSyncLocalRecoveryPending)
        #expect(state.permitsDocumentInteraction == false)
        #expect(await transport.operationCount() == 0)

        await state.resolveWorkSyncLocalRecovery(
            using: .keepRemote,
            expectedReview: review,
            expectedSession: state.documentSessionToken
        )

        #expect(state.document.title == "保存途中の端末版")
        #expect(state.document.characters.map(\.name) == ["保存途中の人物"])
        #expect(state.workSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.permitsDocumentInteraction)
        #expect(await transport.operationCount() == 0)
    }

    @Test("作品同期のCAS再試行を使い切ったlocal tailも自動で再送する")
    func wholeWorkLocalPendingOutcomeReschedulesTail() async throws {
        let fixture = makeFixture(content: "連続編集する本文")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let workID = SyncWorkID()
        let transport = DivergingWorkSyncTransport()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: InMemoryWorkSyncJournal()
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                workTransport: transport,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await waitForWorkSyncNetwork(state)
        #expect(await transport.currentHead(for: workID)?.snapshot.title == fixture.document.title)

        await transport.divergeNextPublishes(4)
        state.updateDocumentTitle("CAS競合後に残った最新版")
        #expect(await state.saveNow())
        await waitForWorkSyncNetwork(state)

        #expect(await transport.currentHead(for: workID)?.snapshot.title == "CAS競合後に残った最新版")
        #expect(await transport.publishCount() >= 5)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("CloudKit bootstrapが停止中でも端末journal復旧後すぐ編集保存できる")
    func wholeWorkLocalPreflightDoesNotWaitForRemoteBinding() async throws {
        let fixture = makeFixture(content: "地下鉄で続ける本文")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workJournal = InMemoryWorkSyncJournal()
        let localResolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .temporarilyOffline
        )
        let remoteResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal
        )
        let remoteResolver = PausableCountingDeviceSyncBindingResolver(resolution: remoteResolution)
        await remoteResolver.pauseNextLookup()
        let workServer = InMemoryWorkSyncServer()
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                workTransport: workServer,
                localWorkBinding: { _, _ in localResolution },
                binding: { _, _ in await remoteResolver.resolve() }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)

        await state.prepareDeviceSync(for: lookup)
        #expect(await remoteResolver.waitUntilLookupIsPaused())
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.deviceSyncAllowsEditing(for: lookup))

        state.updateDocumentTitle("通信待ち中に保存した作品名")
        #expect(await state.saveNow())
        #expect(try await repository.load(from: fixture.url).title == "通信待ち中に保存した作品名")
        #expect(await workJournal.storedRecord(for: workID)?.localHead.snapshot.title
            == "通信待ち中に保存した作品名")
        #expect(await workServer.currentHead(for: workID) == nil)

        await remoteResolver.resumePausedLookup()
        await state.workSyncRemoteBindingTask?.value
        await waitForWorkSyncNetwork(state)
        #expect(await workServer.currentHead(for: workID)?.snapshot.title == "通信待ち中に保存した作品名")
    }

    @Test("remote作品情報が不一致でもlocal journalを使って編集しnetworkを止める")
    func wholeWorkDescriptorMismatchDoesNotLockLocalEditor() async throws {
        let fixture = makeFixture(content: "local first")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workJournal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let mismatch = try DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: workID,
                sourceDocumentID: UUID(),
                structureDigest: SyncWorkStructureDigest(chapters: fixture.document.chapters),
                title: fixture.document.title
            ),
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: workJournal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .available
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                workTransport: transport,
                localWorkBinding: { _, _ in mismatch },
                binding: { _, _ in mismatch }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await state.workSyncRemoteBindingTask?.value

        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.deviceSyncAllowsEditing(for: lookup))
        #expect(state.deviceSyncState == .blocked)
        state.updateDocumentTitle("不一致中も端末へ保存")
        #expect(await state.saveNow())
        #expect(try await repository.load(from: fixture.url).title == "不一致中も端末へ保存")
        #expect(await transport.operationCount() == 0)
    }

    @Test("別項目のオフライン編集はEditorへ途中注入せず安全な離脱時に自動統合する")
    func wholeWorkDisjointOfflineEditsMergeAtSafeDeparture() async throws {
        let fixture = makeFixture(content: "共通本文")
        let workID = SyncWorkID()
        let server = InMemoryWorkSyncServer()
        let seedJournal = InMemoryWorkSyncJournal()
        let seedCoordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: seedJournal
        )
        _ = try await seedCoordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: fixture.document),
            at: Date(timeIntervalSince1970: 1)
        )
        _ = try await seedCoordinator.synchronize(at: Date(timeIntervalSince1970: 2))
        let sharedBase = try #require(await server.currentHead(for: workID))

        let firstReplicaID = SyncReplicaID()
        let secondReplicaID = SyncReplicaID()
        let firstWorkingCopyID = LocalWorkingCopyID()
        let secondWorkingCopyID = LocalWorkingCopyID()
        let firstJournal = InMemoryWorkSyncJournal()
        let secondJournal = InMemoryWorkSyncJournal()
        try await firstJournal.save(sharedWorkJournalRecord(
            base: sharedBase,
            localWorkingCopyID: firstWorkingCopyID,
            replicaID: firstReplicaID
        ))
        try await secondJournal.save(sharedWorkJournalRecord(
            base: sharedBase,
            localWorkingCopyID: secondWorkingCopyID,
            replicaID: secondReplicaID
        ))
        let firstRepository = DeviceSyncAppRepository()
        let secondRepository = DeviceSyncAppRepository()
        let firstURL = packageURL("work-auto-merge-first")
        let secondURL = packageURL("work-auto-merge-second")
        await firstRepository.seed(fixture.document, at: firstURL)
        await secondRepository.seed(fixture.document, at: secondURL)
        let firstResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: firstWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: firstJournal
        )
        let secondResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: secondWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: secondJournal
        )
        let first = makeState(
            repository: firstRepository,
            runtime: DeviceSyncRuntime(
                replicaID: firstReplicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: server,
                binding: { _, _ in firstResolution }
            )
        )
        let second = makeState(
            repository: secondRepository,
            runtime: DeviceSyncRuntime(
                replicaID: secondReplicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: server,
                binding: { _, _ in secondResolution }
            )
        )
        #expect(await first.openDocument(at: firstURL))
        #expect(await second.openDocument(at: secondURL))
        let firstLookup = try #require(first.currentDeviceSyncLookupIdentity)
        let secondLookup = try #require(second.currentDeviceSyncLookupIdentity)
        await first.prepareDeviceSync(for: firstLookup)
        await second.prepareDeviceSync(for: secondLookup)
        await waitForWorkSyncNetwork(first)
        await waitForWorkSyncNetwork(second)

        await server.setOnline(false)
        first.updateDocumentTitle("もう一方で変えた作品名")
        second.updateDocumentSynopsis("この端末で変えたあらすじ")
        #expect(await first.saveNow())
        #expect(await second.saveNow())
        await waitForWorkSyncNetwork(first)
        await waitForWorkSyncNetwork(second)

        await server.setOnline(true)
        await first.refreshWholeWorkSync()
        await waitForWorkSyncNetwork(first)
        await second.refreshWholeWorkSync()
        await waitForWorkSyncNetwork(second)
        let pending = try #require(await secondJournal.storedRecord(for: workID)?.pendingRemoteMaterialization)
        #expect(pending.kind == .automaticMerge)
        #expect(second.document.title == fixture.document.title)
        #expect(second.document.synopsis == "この端末で変えたあらすじ")

        #expect(await second.flushDeviceSyncForBackground())
        await waitForWorkSyncNetwork(second)
        let mergedPackage = try await secondRepository.load(from: secondURL)
        #expect(mergedPackage.title == "もう一方で変えた作品名")
        #expect(mergedPackage.synopsis == "この端末で変えたあらすじ")
        #expect(await server.currentHead(for: workID)?.snapshot.title == "もう一方で変えた作品名")
        #expect(await server.currentHead(for: workID)?.snapshot.synopsis == "この端末で変えたあらすじ")
    }

    @Test("同じ項目の競合は両版を保持し明示choice後だけpackageへ反映する")
    func wholeWorkConflictIsRetainedUntilExplicitChoice() async throws {
        let fixture = makeFixture(content: "共通本文")
        let workID = SyncWorkID()
        let server = InMemoryWorkSyncServer()
        let seedCoordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await seedCoordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: fixture.document),
            at: Date(timeIntervalSince1970: 1)
        )
        _ = try await seedCoordinator.synchronize(at: Date(timeIntervalSince1970: 2))
        let sharedBase = try #require(await server.currentHead(for: workID))

        var remoteDocument = fixture.document
        remoteDocument.title = "iCloudで変更した作品名"
        let remoteReplicaID = SyncReplicaID()
        let remoteWorkingCopyID = LocalWorkingCopyID()
        let remoteJournal = InMemoryWorkSyncJournal()
        try await remoteJournal.save(sharedWorkJournalRecord(
            base: sharedBase,
            localWorkingCopyID: remoteWorkingCopyID,
            replicaID: remoteReplicaID
        ))
        let remoteCoordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: remoteWorkingCopyID,
            replicaID: remoteReplicaID,
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: remoteJournal
        )
        _ = try await remoteCoordinator.restore()
        let remoteRevision = try await remoteCoordinator.stageLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 3)
        )
        try await remoteCoordinator.confirmLocalSnapshotMaterialized(
            remoteRevision.revisionID,
            packageSnapshot: remoteRevision.snapshot
        )
        _ = try await remoteCoordinator.synchronize(at: Date(timeIntervalSince1970: 4))

        var localDocument = fixture.document
        localDocument.title = "このMacで変更した作品名"
        let localReplicaID = SyncReplicaID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let localJournal = InMemoryWorkSyncJournal()
        try await localJournal.save(sharedWorkJournalRecord(
            base: sharedBase,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: localReplicaID
        ))
        let localCoordinator = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: localReplicaID,
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: localJournal
        )
        _ = try await localCoordinator.restore()
        let localRevision = try await localCoordinator.stageLocalSnapshot(
            WorkSnapshot(document: localDocument),
            at: Date(timeIntervalSince1970: 5)
        )
        try await localCoordinator.confirmLocalSnapshotMaterialized(
            localRevision.revisionID,
            packageSnapshot: localRevision.snapshot
        )

        let url = packageURL("work-conflict-choice")
        let repository = DeviceSyncAppRepository()
        await repository.seed(localDocument, at: url)
        let resolution = try makeResolution(
            document: localDocument,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: localJournal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: localReplicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        await waitForWorkSyncNetwork(state)
        let review = try #require(state.workSyncConflictReview)
        #expect(state.document.title == "このMacで変更した作品名")
        #expect(await localJournal.storedRecord(for: workID)?.conflictReview == review)

        await state.resolveWorkSyncConflict(
            using: .keepRemote,
            expectedReview: review,
            expectedSession: state.documentSessionToken
        )
        await waitForWorkSyncNetwork(state)

        #expect(try await repository.load(from: url).title == "iCloudで変更した作品名")
        #expect(state.workSyncConflictReview == nil)
        #expect(await localJournal.storedRecord(for: workID)?.conflictReview == nil)
        #expect(await server.currentHead(for: workID)?.snapshot.title == "iCloudで変更した作品名")
    }

    @Test("作品preflightはbinding待ち中の最新本文とフォーム値を先に二相保存する")
    func wholeWorkPreflightPreservesEditsMadeWhileBindingWaits() async throws {
        let fixture = makeFixture(content: "前回の本文")
        var remoteDocument = fixture.document
        remoteDocument.title = "remote作品名"
        remoteDocument.synopsis = "remoteあらすじ"
        let episodeID = try #require(remoteDocument.chapters.first?.episodes.first?.id)
        try remoteDocument.updateEpisodeContent(
            "remote本文",
            for: episodeID,
            in: #require(remoteDocument.chapters.first?.id)
        )
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        try await journal.save(pendingRemoteWorkRecord(
            baseDocument: fixture.document,
            remoteDocument: remoteDocument,
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID
        ))
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: [episodeID],
            remoteAvailability: .configurationBlocked
        )
        let resolver = PausableCountingDeviceSyncBindingResolver(resolution: resolution)
        await resolver.pauseNextLookup()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let committedText = WorkSyncCommittedTextCapture()
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: CountingWorkSyncTransport(),
                localWorkBinding: { _, _ in await resolver.resolve() },
                binding: { _, _ in resolution }
            ),
            activeCommittedTextCapture: { committedText.capture() }
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let preparation = Task { await state.prepareDeviceSync(for: lookup) }
        #expect(await resolver.waitUntilLookupIsPaused())
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.deviceSyncAllowsEditing(for: lookup))

        state.updateDocumentTitle("binding待ち中の作品名")
        state.updateDocumentSynopsis("binding待ち中のあらすじ")
        committedText.content = "binding待ち中の未debounce本文"
        await resolver.resumePausedLookup()
        await preparation.value

        let package = try await repository.load(from: fixture.url)
        let durable = try #require(await journal.storedRecord(for: workID))
        #expect(package.title == "binding待ち中の作品名")
        #expect(package.synopsis == "binding待ち中のあらすじ")
        #expect(package.episode(episodeID)?.episode.content == "binding待ち中の未debounce本文")
        #expect(durable.localHead.snapshot.title == "binding待ち中の作品名")
        #expect(durable.localHead.snapshot.synopsis == "binding待ち中のあらすじ")
        #expect(durable.localHead.snapshot.episodes.first?.content == "binding待ち中の未debounce本文")
        #expect(durable.stagedLocalRevision == nil)
        #expect(state.document.title == "binding待ち中の作品名")
        #expect(state.workSyncConflictReview?.local.snapshot.title == "binding待ち中の作品名")
    }

    @Test("作品journal restore中の話切替はpreflight完了までshortcutしない")
    func wholeWorkRestoreKeepsSelectionGatedUntilRecoveryIsDurable() async throws {
        var document = makeFixture(content: "前回の本文").document
        let chapterID = try #require(document.chapters.first?.id)
        let firstEpisodeID = try #require(document.chapters.first?.episodes.first?.id)
        let secondEpisode = Episode(title: "第二話", content: "第二話本文")
        document.chapters[0].episodes.append(secondEpisode)
        var remoteDocument = document
        remoteDocument.title = "復旧するremote作品名"
        let url = packageURL("work-restore-selection-gate")
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = FailingWorkSyncJournal()
        try await journal.save(pendingRemoteWorkRecord(
            baseDocument: document,
            remoteDocument: remoteDocument,
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID
        ))
        await journal.pauseNextLoad()
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: [firstEpisodeID, secondEpisode.id],
            remoteAvailability: .configurationBlocked
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: CountingWorkSyncTransport(),
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let preparation = Task { await state.prepareDeviceSync(for: lookup) }
        #expect(await journal.waitUntilLoadIsPaused())
        #expect(state.deviceSyncLocalRecoveryPending)
        #expect(state.deviceSyncAllowsEditing(for: lookup) == false)

        state.selectEpisode(secondEpisode.id, in: chapterID)
        #expect(state.selectedEpisodeID == firstEpisodeID)
        await journal.resumePausedLoad()
        await preparation.value

        let package = try await repository.load(from: url)
        let durable = try #require(await journal.storedRecord(for: workID))
        #expect(package.title == "復旧するremote作品名")
        #expect(durable.pendingRemoteMaterialization == nil)
        #expect(durable.localHead.snapshot.title == "復旧するremote作品名")
        #expect(state.deviceSyncLocalRecoveryPending == false)
        #expect(state.selectedEpisodeID == firstEpisodeID)
    }

    @Test("競合choiceはjournal stage失敗後のpackage tailを旧reviewで消さない")
    func workConflictChoiceRejectsStaleReviewAfterStageFailure() async throws {
        try await assertWorkConflictChoicePreservesPackageTail(
            successfulSavesBeforeFailure: 0
        )
    }

    @Test("競合choiceはjournal confirm失敗後のpackage tailを旧reviewで消さない")
    func workConflictChoiceRejectsStaleReviewAfterConfirmationFailure() async throws {
        try await assertWorkConflictChoicePreservesPackageTail(
            successfulSavesBeforeFailure: 1
        )
    }

    @Test("競合choice保存失敗後は旧3択を閉じ最初の選択だけを再試行する")
    func workConflictMaterializationFailureDoesNotAcceptOppositeStaleChoice() async throws {
        let fixture = makeFixture(content: "競合中の本文")
        var baseDocument = fixture.document
        baseDocument.title = "共通作品名"
        var localDocument = fixture.document
        localDocument.title = "このMacの競合版"
        var remoteDocument = fixture.document
        remoteDocument.title = "iCloudの競合版"
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = InMemoryWorkSyncJournal()
        try await journal.save(conflictedWorkRecord(
            baseDocument: baseDocument,
            localDocument: localDocument,
            remoteDocument: remoteDocument,
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID
        ))
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: Set(localDocument.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .configurationBlocked
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(localDocument, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: CountingWorkSyncTransport(),
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let oldReview = try #require(state.workSyncConflictReview)
        await repository.failNextSave()

        await state.resolveWorkSyncConflict(
            using: .keepRemote,
            expectedReview: oldReview,
            expectedSession: state.documentSessionToken
        )

        let firstPending = try #require(await journal.storedRecord(for: workID)?.pendingRemoteMaterialization)
        #expect(firstPending.revision.snapshot.title == "iCloudの競合版")
        #expect(try await repository.load(from: fixture.url).title == "このMacの競合版")
        #expect(state.workSyncConflictReview == nil)
        #expect(state.deviceSyncState == .syncing)
        #expect(state.deviceSyncLocalDurabilityState == .failed)

        // 旧sheetから届いた逆choiceは、最初のdurable choiceを差し替えない。
        await state.resolveWorkSyncConflict(
            using: .keepLocal,
            expectedReview: oldReview,
            expectedSession: state.documentSessionToken
        )
        let retainedPending = try #require(await journal.storedRecord(for: workID)?.pendingRemoteMaterialization)
        #expect(retainedPending.revision.revisionID == firstPending.revision.revisionID)
        #expect(retainedPending.revision.snapshot.title == "iCloudの競合版")
        #expect(try await repository.load(from: fixture.url).title == "このMacの競合版")

        // 次の安全な保存境界は、利用者が最初に選んだ版だけを再試行する。
        #expect(await state.flushDeviceSyncForBackground())
        #expect(try await repository.load(from: fixture.url).title == "iCloudの競合版")
        #expect(await journal.storedRecord(for: workID)?.pendingRemoteMaterialization == nil)
    }

    @Test("runtime未設定なら従来どおりlocal本文を編集できる")
    func localOnlyDocumentRemainsEditable() async throws {
        let fixture = makeFixture(content: "local")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository)

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)

        #expect(state.deviceSyncState == .unconfigured)
        #expect(state.deviceSyncAllowsEditing(for: lookup))
    }

    @Test("remote状態はlocal editorの入力可否を変えない")
    func remoteStateNeverLocksLocalEditor() async throws {
        let fixture = makeFixture(content: "local-first")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository)

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: lookup.episodeID)
        let local = try revision(key: key, parents: [], content: "local")
        let remote = try revision(key: key, parents: [], content: "remote")
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)

        for remoteState in [
            DeviceSyncUIState.readOnly,
            .forcing,
            .offlineLocal,
            .conflict(conflict),
            .syncing,
            .blocked
        ] {
            state.deviceSyncState = remoteState
            #expect(state.deviceSyncAllowsEditing(for: lookup))
        }
    }

    @Test("保存記号は端末保存・iCloud・オフライン・統合必要をVoiceOverで区別する")
    func editorStatusDistinguishesDurabilityAndPropagation() throws {
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
        let local = try revision(key: key, parents: [], content: "local")
        let remote = try revision(key: key, parents: [], content: "remote")
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)

        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .unconfigured,
            transferState: .notApplicable,
            localDurability: .notApplicable
        ).accessibilityLabel == "この端末に保存済み")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .writer,
            transferState: .upToDate,
            localDurability: .saved
        ).accessibilityLabel == "作品データをこの端末とiCloudに同期済み")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .offlineLocal,
            transferState: .localPending,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、オフライン")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .conflict(conflict),
            transferState: .localPending,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、統合が必要")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .blocked,
            transferState: .notApplicable,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、同期設定を確認")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .offlineLocal,
            transferState: .localPending,
            localDurability: .savedSyncPreparationFailed
        ).accessibilityLabel == "この端末に保存済み、同期準備を再試行")

        let pendingReview = DeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .pending,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: true,
            reviewChanges: {}
        )
        #expect(pendingReview.resolvedStatus == .savingLocally)
        let failedReview = DeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .failed,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: false,
            reviewChanges: {}
        )
        #expect(failedReview.resolvedStatus == .localSaveError)
        let durableReview = DeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .saved,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: true,
            reviewChanges: {}
        )
        #expect(durableReview.resolvedStatus == .needsReview)
    }

    @Test("本文WALは最新一件だけを保持し再起動sequenceとJSON escape境界を安全に読む")
    func productionEditIntentStoreKeepsOnlyLatestBody() async throws {
        let fileManager = FileManager.default
        let trusted = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-WAL-Latest-\(UUID().uuidString)", isDirectory: true)
        let root = trusted
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("DeviceSync-v1", isDirectory: true)
        try fileManager.createDirectory(at: trusted, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: trusted) }
        let store = try FileDeviceSyncEditIntentStore(rootURL: root, trustedAncestorURL: trusted)
        let documentID = UUID()
        let episodeID = EpisodeID()
        let old = editIntentMarker(content: "old", sequence: 100, documentID: documentID, episodeID: episodeID)
        let latest = editIntentMarker(content: "latest", sequence: 101, documentID: documentID, episodeID: episodeID)

        try await store.save(old)
        try await store.save(latest)
        try await store.remove(old)
        var loaded = try await store.load(
            workingCopyIdentity: latest.workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        #expect(loaded == [latest])

        for sequence in 102 ... 1000 {
            try await store.save(editIntentMarker(
                content: "body-\(sequence)",
                sequence: UInt64(sequence),
                documentID: documentID,
                episodeID: episodeID
            ))
        }
        loaded = try await store.load(
            workingCopyIdentity: latest.workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "body-1000")
        #expect(try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)

        let escapedEpisodeID = EpisodeID()
        let escapedBody = String(repeating: "\u{0000}", count: 1_048_576)
        let escaped = editIntentMarker(
            content: escapedBody,
            sequence: 1,
            documentID: documentID,
            episodeID: escapedEpisodeID
        )
        try await store.save(escaped)
        #expect(try await store.load(
            workingCopyIdentity: escaped.workingCopyIdentity,
            documentID: documentID,
            episodeID: escapedEpisodeID
        ) == [escaped])

        let oversized = editIntentMarker(
            content: String(repeating: "x", count: 1_048_577),
            sequence: 2,
            documentID: documentID,
            episodeID: EpisodeID()
        )
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            try await store.save(oversized)
        }
    }

    @Test("本文WALは中間symlink・root差し替え・最終symlinkを拒否する")
    func productionEditIntentStorePinsTrustedRoot() async throws {
        let fileManager = FileManager.default
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-WAL-Root-\(UUID().uuidString)", isDirectory: true)
        let trusted = base.appendingPathComponent("trusted", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: trusted, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let linkedParent = trusted.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try FileDeviceSyncEditIntentStore(
                rootURL: linkedParent.appendingPathComponent("DeviceSync-v1", isDirectory: true),
                trustedAncestorURL: trusted
            )
        }

        let root = trusted.appendingPathComponent("pinned", isDirectory: true)
        let store = try FileDeviceSyncEditIntentStore(rootURL: root, trustedAncestorURL: trusted)
        let marker = editIntentMarker(content: "safe", sequence: 1)
        let moved = trusted.appendingPathComponent("moved", isDirectory: true)
        try fileManager.moveItem(at: root, to: moved)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            try await store.save(marker)
        }

        let finalRoot = trusted.appendingPathComponent("final", isDirectory: true)
        let finalStore = try FileDeviceSyncEditIntentStore(rootURL: finalRoot, trustedAncestorURL: trusted)
        try await finalStore.save(marker)
        let recordURL = try #require(
            fileManager.contentsOfDirectory(at: finalRoot, includingPropertiesForKeys: nil).first
        )
        try fileManager.removeItem(at: recordURL)
        let forged = outside.appendingPathComponent("forged.json")
        try Data("forged".utf8).write(to: forged)
        try fileManager.createSymbolicLink(at: recordURL, withDestinationURL: forged)
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try await finalStore.load(
                workingCopyIdentity: marker.workingCopyIdentity,
                documentID: marker.documentID,
                episodeID: marker.episodeID
            )
        }
    }

    @Test("同一sequenceの異なる本文または復旧参照でWALを上書きしない")
    func editIntentStoreRejectsDifferentPayloadAtSameSequence() async throws {
        let store = InMemoryDeviceSyncEditIntentStore()
        let documentID = UUID()
        let episodeID = EpisodeID()
        let first = editIntentMarker(
            content: "first",
            sequence: 1,
            documentID: documentID,
            episodeID: episodeID
        )
        _ = try await store.save(
            first,
            baselinePackageDigest: SyncContentDigest(content: "base")
        )
        let differentContent = editIntentMarker(
            content: "second",
            sequence: 1,
            documentID: documentID,
            episodeID: episodeID
        )
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try await store.save(
                differentContent,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
        }
        var differentResolution = first
        differentResolution.resolvesPreservedSequences = [1]
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try await store.save(
                differentResolution,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
        }
    }

    @Test("初回本文WALだけが残った再起動はbase一致時だけ最新本文を復元する")
    func firstBoundIntentRecoversBeforeAnyJournalBaseline() async throws {
        let fixture = makeFixture(content: "P0 package")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let resolver = DelayedDeviceSyncBindingResolver()
        let replicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: server,
                binding: { session, _ in
                    await resolver.resolve(session)
                },
                editIntentStore: editIntents
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let session = state.documentSessionToken
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: session),
            documentID: session.documentID,
            episodeID: episodeID,
            editorContentGeneration: state.editorContentGeneration,
            mutationSequence: 2,
            createdAt: Date(timeIntervalSince1970: 2),
            replicaID: replicaID,
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            workID: resolution.binding.workID,
            baseContentDigest: SyncContentDigest(content: "P0 package"),
            acceptedPriorPackageDigests: [SyncContentDigest(content: "P0 package")],
            content: "P2 WAL latest",
            contentDigest: SyncContentDigest(content: "P2 WAL latest")
        )
        try await editIntents.save(marker)
        await repository.pauseNextSave()

        let originalLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let firstPreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: originalLookup)
        }
        try #require(await repository.waitUntilSaveIsPaused())
        let recoveredLookup = try #require(state.currentDeviceSyncLookupIdentity)
        #expect(recoveredLookup != originalLookup)
        let duplicatePreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: recoveredLookup)
        }
        await Task.yield()
        #expect(await resolver.observedLookupCount() == 0)
        await repository.resumePausedSave()
        try #require(await resolver.waitUntilFirstLookupIsPaused())
        #expect(await resolver.observedLookupCount() == 1)
        await resolver.resumeFirstLookup(with: resolution)
        await firstPreparation.value
        await duplicatePreparation.value

        let package = try await repository.load(from: fixture.url)
        let record = try #require(await journal.storedRecord(
            for: EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        ))
        #expect(state.document.episode(episodeID)?.episode.content == "P2 WAL latest")
        #expect(package.episode(episodeID)?.episode.content == "P2 WAL latest")
        #expect(record.localHead.content == "P2 WAL latest")
        #expect(await server.currentHead(for: record.key)?.content == "P2 WAL latest")
        #expect(await resolver.observedLookupCount() == 1)
        #expect(try await editIntents.load(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        ).isEmpty)
    }

    @Test("本文WAL失敗後のpackage checkpointだけでも再起動時に明示編集を復元する")
    func packageCheckpointRecoversEditWhenIntentMarkerWasNotSaved() async throws {
        let fixture = makeFixture(content: "package survived")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let runtime = DeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let first = makeState(repository: repository, runtime: runtime)
        #expect(await first.openDocument(at: fixture.url))
        let session = first.documentSessionToken
        let checkpoint = DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: first.deviceSyncWorkingCopyIdentity(for: session),
            documentID: session.documentID,
            episodeID: episodeID,
            sequence: 1,
            contentDigest: SyncContentDigest(content: "package survived"),
            containsLocalEditIntent: true
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: fixture.url))
        try await relaunched.prepareDeviceSync(
            for: #require(relaunched.currentDeviceSyncLookupIdentity)
        )

        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        )?.content == "package survived")
        let persisted = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
        #expect(persisted.committedPackage?.containsLocalEditIntent == false)
    }

    @Test("隔離した本文は未設定作品で編集を続けても削除・remote送信しない")
    func preservedRecoveryRemainsUntilRemoteAcknowledgement() async throws {
        let fixture = makeFixture(content: "current package")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let runtimeReplicaID = SyncReplicaID()
        let runtime = DeviceSyncRuntime(
            replicaID: runtimeReplicaID,
            transport: server,
            binding: { _, _ in nil },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "current package"),
            acceptedPriorPackageDigests: nil,
            content: "preserved body",
            contentDigest: SyncContentDigest(content: "preserved body")
        )
        _ = try await editIntents.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "current package")
        )

        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)
        #expect(state.deviceSyncState == .needsReview)
        #expect(state.deviceSyncAllowsEditing(for: lookup))
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)

        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(snapshot.preservedMarkers == [marker])
        #expect(state.deviceSyncLocalRecoveryReview != nil)
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        ) == nil)
    }

    @Test("隔離上限では4本文を保持して選択・remote送信を拒否する")
    func preservedRecoveryCapacityFailsClosedWithoutOverwritingActiveEvidence() async throws {
        let fixture = makeFixture(content: "package body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in nil },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let workingCopyIdentity = state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession)
        let marker: (UInt64) -> DeviceSyncEditIntentMarker = { sequence in
            let content = "recovery body \(sequence)"
            return DeviceSyncEditIntentMarker(
                protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
                workingCopyIdentity: workingCopyIdentity,
                documentID: lookup.documentSession.documentID,
                episodeID: episodeID,
                editorContentGeneration: lookup.editorContentGeneration,
                mutationSequence: sequence,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                replicaID: SyncReplicaID(),
                localWorkingCopyID: nil,
                workID: nil,
                baseContentDigest: SyncContentDigest(content: "package body"),
                acceptedPriorPackageDigests: nil,
                content: content,
                contentDigest: SyncContentDigest(content: content)
            )
        }
        for sequence in 1 ... 3 {
            let evidence = marker(UInt64(sequence))
            _ = try await editIntents.save(
                evidence,
                baselinePackageDigest: SyncContentDigest(content: "package body")
            )
            try await editIntents.preserveForReview(evidence)
        }
        let active = marker(4)
        _ = try await editIntents.save(
            active,
            baselinePackageDigest: SyncContentDigest(content: "package body")
        )

        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)
        #expect(review.preservedMarkers.count == 4)
        #expect(state.deviceSyncLocalRecoveryPending)
        #expect(state.deviceSyncLocalDurabilityState == .failed)
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)

        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID
        )
        #expect(snapshot.preservedMarkers.count == 3)
        #expect(snapshot.marker == active)
        #expect(state.document.episode(episodeID)?.episode.content == "package body")
        #expect(state.activeDeviceSyncIdentity == nil)
    }

    @Test("隔離本文はpackage・journal・remote確認後だけまとめて削除する")
    func preservedRecoveryClearsAfterRemoteAcknowledgement() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "preserved body",
            contentDigest: SyncContentDigest(content: "preserved body")
        )
        _ = try await editIntents.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)

        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        for _ in 0 ..< 100 where state.deviceSyncLocalRecoveryReview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "accepted body")
        #expect(state.deviceSyncLocalRecoveryReview == nil)
        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(snapshot.preservedMarkers.isEmpty)
    }

    @Test("同一本文の古い復旧証拠を選んでも新しいsequenceでremote確認まで完了する")
    func sameBodyRecoveryChoiceAdvancesSequenceBeforeAcknowledgement() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "accepted body",
            contentDigest: SyncContentDigest(content: "accepted body")
        )
        _ = try await editIntents.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        let checkpoint = DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID,
            sequence: 1,
            contentDigest: marker.contentDigest,
            containsLocalEditIntent: false
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)
        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)
        await editIntents.pauseNextPreservedRemoval()
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        #expect(await editIntents.waitUntilPreservedRemovalIsPaused())

        let staged = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(staged.marker?.mutationSequence == 2)
        #expect(staged.marker?.resolvesPreservedSequences == [1])

        await editIntents.resumePausedPreservedRemoval()
        for _ in 0 ..< 100 where state.deviceSyncLocalRecoveryReview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "accepted body")
        let completed = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(completed.marker == nil)
        #expect(completed.preservedMarkers.isEmpty)
    }

    @Test("新しいpackage checkpointは古いWALを次sequenceへ置換して再起動復旧する")
    func newerPackageCheckpointSupersedesStaleMarkerWithNewSequence() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let runtime = DeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let stale = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: replicaID,
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "stale body",
            contentDigest: SyncContentDigest(content: "stale body")
        )
        _ = try await editIntents.save(
            stale,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        let checkpoint = DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID,
            sequence: 2,
            contentDigest: SyncContentDigest(content: "accepted body"),
            containsLocalEditIntent: true
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)
        let seeded = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID
        )
        #expect(seeded.marker == stale)
        #expect(seeded.committedPackage == checkpoint)
        #expect(state.deviceSyncPreparationTask == nil)

        await state.prepareDeviceSync(for: lookup)
        for _ in 0 ..< 100 {
            if await server.currentHead(
                for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
            ) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(state.document.episode(episodeID)?.episode.content == "accepted body")
        #expect(state.deviceSyncAllowsEditing(for: lookup))
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "accepted body")
        let completed = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID
        )
        #expect(completed.marker == nil)
        #expect(completed.committedPackage?.containsLocalEditIntent == false)
    }

    @Test("古いremote確認は同本文へ戻った新しいWALを削除しない")
    func staleRecoveryCompletionCannotDeleteNetZeroTailMarker() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let workID = SyncWorkID()
        let runtimeReplicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: runtimeReplicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let evidence = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "preserved body",
            contentDigest: SyncContentDigest(content: "preserved body")
        )
        _ = try await editIntents.save(
            evidence,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)

        await editIntents.pauseNextPreservedRemoval()
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        #expect(await editIntents.waitUntilPreservedRemovalIsPaused())

        let tailLookup = try #require(state.currentDeviceSyncLookupIdentity)
        state.updateEpisodeContent(
            "temporary tail",
            for: episodeID,
            in: tailLookup.chapterID,
            expectedSession: tailLookup.documentSession,
            expectedEditorContentGeneration: tailLookup.editorContentGeneration
        )
        state.updateEpisodeContent(
            "accepted body",
            for: episodeID,
            in: tailLookup.chapterID,
            expectedSession: tailLookup.documentSession,
            expectedEditorContentGeneration: tailLookup.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        #expect(await state.flushPendingDeviceSyncEditIntents())
        state.saveCoordinator.markDirty()
        #expect(await state.saveCoordinator.saveNow())
        let identity = try #require(state.activeDeviceSyncIdentity)
        let client = try #require(state.deviceSyncClient(for: identity))
        let tailSnapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        let tailMarker = try #require(tailSnapshot.marker)
        let tailReceipt = try await client.coordinator.recordLocalEdit(
            "accepted body",
            createdAt: runtime.now()
        )
        await state.markDeviceSyncLocalEditSavedIfCurrent(
            tailReceipt,
            content: "accepted body",
            expectedIdentity: identity,
            acknowledgedMutationSequence: tailMarker.mutationSequence
        )
        state.applyDeviceSyncState(tailReceipt.state, client: client, expectedIdentity: identity)

        await editIntents.resumePausedPreservedRemoval()
        for _ in 0 ..< 20 where state.deviceSyncState != .needsReview {
            await Task.yield()
        }
        var retained = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        #expect(retained.preservedMarkers == [evidence])
        #expect(retained.marker == tailMarker)
        #expect(state.deviceSyncLocalRecoveryReview != nil)

        let synchronized = try await client.coordinator.synchronizeLocalFirst(
            expiresAt: runtime.leaseExpiration(),
            createdAt: runtime.now()
        )
        #expect(await state.completeDeviceSyncLocalRecoveryReviewIfConfirmed(
            state: synchronized,
            client: client,
            identity: identity,
            runtime: runtime
        ))
        retained = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        #expect(retained.marker == nil)
        #expect(retained.preservedMarkers.isEmpty)
    }

    @Test("private copyの事前採用検査失敗は元sessionとURLを変えない")
    func rejectedPrivateCopyDoesNotAdoptDestination() async {
        let fixture = makeFixture(content: "source")
        let destination = packageURL("rejected-private-copy")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository)
        #expect(await state.openDocument(at: fixture.url))
        let originalSession = state.documentSessionToken
        let originalURL = state.documentURL

        let result = await state.saveDocumentResult(
            as: destination,
            expectedSession: originalSession,
            preAdoptionValidation: { _ in
                throw DeviceSyncAppRepositoryError.rejectedPrivateCopy
            }
        )

        #expect(result == .failedBeforeSwitch)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.documentURL == originalURL)
        #expect(state.document.episode(fixture.document.chapters[0].episodes[0].id)?.episode.content == "source")
    }

    @Test("private working-copy rootはsymlinkとroot identity差し替えを拒否する")
    func privateWorkingCopyRootRejectsSymlinksAndReplacement() throws {
        let fileManager = FileManager.default
        let applicationSupport = try #require(
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let sandbox = applicationSupport
            .appendingPathComponent("FUMINIWA-Private-Root-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let realParent = sandbox.appendingPathComponent("real", isDirectory: true)
        try fileManager.createDirectory(at: realParent, withIntermediateDirectories: true)
        let alias = sandbox.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: realParent)
        var rejectedAncestorSymlink = false
        do {
            _ = try DeviceSyncPrivateWorkingCopyRoot.prepare(
                alias.appendingPathComponent("root", isDirectory: true),
                fileManager: fileManager
            )
        } catch {
            rejectedAncestorSymlink = true
        }
        #expect(rejectedAncestorSymlink)

        let actualRoot = sandbox.appendingPathComponent("actual-root", isDirectory: true)
        try fileManager.createDirectory(at: actualRoot, withIntermediateDirectories: false)
        let finalRootLink = sandbox.appendingPathComponent("root-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: finalRootLink, withDestinationURL: actualRoot)
        var rejectedFinalSymlink = false
        do {
            _ = try DeviceSyncPrivateWorkingCopyRoot.prepare(
                finalRootLink,
                fileManager: fileManager
            )
        } catch {
            rejectedFinalSymlink = true
        }
        #expect(rejectedFinalSymlink)

        let rootURL = sandbox.appendingPathComponent("fixed", isDirectory: true)
        let root = try DeviceSyncPrivateWorkingCopyRoot.prepare(rootURL, fileManager: fileManager)
        let packageURL = rootURL.appendingPathComponent("copy.novelpkg", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        try root.validateCopiedPackage(at: packageURL)

        let movedRoot = sandbox.appendingPathComponent("moved", isDirectory: true)
        try fileManager.moveItem(at: rootURL, to: movedRoot)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
        var rejectedReplacement = false
        do {
            try root.validateFixedRoot()
        } catch {
            rejectedReplacement = true
        }
        #expect(rejectedReplacement)
    }

    @Test("production sync準備失敗は外部openや新規作成で迂回できない")
    func deviceSyncStartupFailureIsSticky() async {
        let repository = DeviceSyncAppRepository()
        let state = makeState(repository: repository)
        let originalDocument = state.document
        let originalSession = state.documentSessionToken

        state.failStartupForDeviceSyncSafety()

        guard case let .recovery(context) = state.startupState else {
            Issue.record("Device Syncの安全停止がRecoveryになっていません。")
            return
        }
        #expect(context.reason == .deviceSyncSafetyUnavailable)
        #expect(!state.permitsDocumentInteraction)
        #expect(!state.permitsDocumentChoice)
        #expect(!state.permitsLongRunningDocumentOperation)
        #expect(await !(state.openExternalDocument(at: packageURL("blocked-open"))))
        #expect(await !(state.createNewDocument(expectedSession: originalSession)))
        await state.retryStartup()
        #expect(state.document == originalDocument)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.deviceSyncStartupFailedSafely)
    }

    @Test("遅い旧binding lookupは新しい話の同期状態を上書きしない")
    func staleBindingLookupCannotOverwriteNewSelection() async throws {
        let firstEpisode = Episode(content: "first")
        let secondEpisode = Episode(content: "second")
        let document = NovelDocument(
            title: "lookup race",
            chapters: [
                Chapter(title: "first", episodes: [firstEpisode]),
                Chapter(title: "second", episodes: [secondEpisode])
            ]
        )
        let url = packageURL("lookup-race")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let resolver = DelayedDeviceSyncBindingResolver()
        let server = InMemoryEpisodeSyncServer()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { session, _ in
                await resolver.resolve(session)
            }
        )
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: url))
        let staleLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let staleTask = Task { @MainActor in
            await state.prepareDeviceSync(for: staleLookup)
        }
        try #require(await resolver.waitUntilFirstLookupIsPaused())

        let secondChapter = document.chapters[1]
        state.selectChapter(secondChapter.id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let currentTask = Task { @MainActor in
            await state.prepareDeviceSync(for: currentLookup)
        }
        for _ in 0 ..< 100 {
            if state.deviceSyncAllowsEditing(for: currentLookup) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.deviceSyncAllowsEditing(for: currentLookup))
        #expect(await resolver.observedLookupCount() == 2)

        try await resolver.resumeFirstLookup(
            with: makeResolution(
                document: document,
                localWorkingCopyID: LocalWorkingCopyID(),
                workID: SyncWorkID(),
                journal: InMemoryEpisodeSyncJournal()
            )
        )
        await staleTask.value
        await currentTask.value

        #expect(state.currentDeviceSyncLookupIdentity == currentLookup)
        #expect(state.resolvedDeviceSyncLookupIdentity == currentLookup)
        #expect(state.activeDeviceSyncIdentity == nil)
        #expect(state.deviceSyncState == .unconfigured)
    }

    @Test("旧話のWAL隔離完了は新しい話の本文と復旧状態を上書きしない")
    func stalePreservedMarkerCompletionCannotOverwriteNewSelection() async throws {
        let firstEpisode = Episode(content: "old package")
        let secondEpisode = Episode(content: "new package")
        let document = NovelDocument(
            title: "stale local recovery",
            chapters: [
                Chapter(title: "old", episodes: [firstEpisode]),
                Chapter(title: "new", episodes: [secondEpisode])
            ]
        )
        let url = packageURL("stale-local-recovery")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let store = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let server = InMemoryEpisodeSyncServer()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in nil },
            editIntentStore: store
        )
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: url))
        let staleLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: staleLookup.documentSession),
            documentID: staleLookup.documentSession.documentID,
            episodeID: firstEpisode.id,
            editorContentGeneration: staleLookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "old package"),
            acceptedPriorPackageDigests: [SyncContentDigest(content: "old package")],
            content: "old recovered branch",
            contentDigest: SyncContentDigest(content: "old recovered branch")
        )
        _ = try await store.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "old package")
        )
        await store.pauseNextPreservation()
        let stalePreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: staleLookup)
        }
        #expect(await store.waitUntilPreservationIsPaused())

        state.selectChapter(document.chapters[1].id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: currentLookup)
        #expect(state.deviceSyncAllowsEditing(for: currentLookup))
        state.updateEpisodeContent(
            "new edited body",
            for: secondEpisode.id,
            in: document.chapters[1].id,
            expectedSession: currentLookup.documentSession,
            expectedEditorContentGeneration: currentLookup.editorContentGeneration
        )
        #expect(await state.saveNow())

        await store.resumePausedPreservation()
        await stalePreparation.value

        let oldSnapshot = try await store.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(oldSnapshot.marker == nil)
        #expect(oldSnapshot.preservedMarkers == [marker])
        #expect(state.document.episode(secondEpisode.id)?.episode.content == "new edited body")
        #expect(state.currentDeviceSyncLookupIdentity?.episodeID == secondEpisode.id)
        #expect(state.deviceSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncState == .unconfigured)
        #expect(await server.snapshotFetchInvocationCount() == 0)
    }

    @Test("旧話のpackage-only完了は新しい話の保存状態を上書きしない")
    func stalePackageOnlyCompletionCannotOverwriteNewSelection() async throws {
        let firstEpisode = Episode(content: "old local")
        let secondEpisode = Episode(content: "new local")
        let document = NovelDocument(
            title: "stale package only",
            chapters: [
                Chapter(title: "old", episodes: [firstEpisode]),
                Chapter(title: "new", episodes: [secondEpisode])
            ]
        )
        let url = packageURL("stale-package-only")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let store = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let server = InMemoryEpisodeSyncServer()
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in nil },
                editIntentStore: store
            )
        )
        #expect(await state.openDocument(at: url))
        let staleLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await store.pauseReconcilePreparedPackage(episodeID: firstEpisode.id, invocation: 2)
        let stalePreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: staleLookup)
        }
        #expect(await store.waitUntilReconcileIsPaused())

        state.selectChapter(document.chapters[1].id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: currentLookup)
        #expect(state.deviceSyncAllowsEditing(for: currentLookup))
        state.updateEpisodeContent(
            "new package-only edit",
            for: secondEpisode.id,
            in: document.chapters[1].id,
            expectedSession: currentLookup.documentSession,
            expectedEditorContentGeneration: currentLookup.editorContentGeneration
        )
        #expect(await state.saveNow())
        let stateBeforeResume = state.deviceSyncState
        let durabilityBeforeResume = state.deviceSyncLocalDurabilityState

        await store.resumePausedReconcile()
        await stalePreparation.value

        #expect(state.document.episode(secondEpisode.id)?.episode.content == "new package-only edit")
        #expect(state.currentDeviceSyncLookupIdentity?.episodeID == secondEpisode.id)
        #expect(state.deviceSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncState == stateBeforeResume)
        #expect(state.deviceSyncLocalDurabilityState == durabilityBeforeResume)
        #expect(await server.snapshotFetchInvocationCount() == 0)
    }

    @Test("同じ話の同期準備は一つのbinding lookupへ合流する")
    func duplicatePreparationJoinsSingleBindingLookup() async throws {
        let fixture = makeFixture(content: "single flight")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolver = DelayedDeviceSyncBindingResolver()
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                binding: { session, _ in
                    await resolver.resolve(session)
                }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)

        let first = Task { @MainActor in
            await state.prepareDeviceSync(for: lookup)
        }
        try #require(await resolver.waitUntilFirstLookupIsPaused())
        let second = Task { @MainActor in
            await state.prepareDeviceSync(for: lookup)
        }
        await Task.yield()

        #expect(await resolver.observedLookupCount() == 1)
        await resolver.resumeFirstLookup(with: nil)
        await first.value
        await second.value

        #expect(await resolver.observedLookupCount() == 1)
        #expect(state.deviceSyncState == .unconfigured)
        #expect(state.resolvedDeviceSyncLookupIdentity == lookup)
    }

    @Test("local-only準備中のready通知は同じEditorを再解決して保留本文を送る")
    func readySignalDuringLocalOnlyPreparationIsRevalidated() async throws {
        let fixture = makeFixture(content: "local base")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(localWorkingCopyID: localWorkingCopyID, workID: workID)
        let descriptor = try SyncWorkDescriptor(
            workID: workID,
            sourceDocumentID: fixture.document.id,
            structureDigest: SyncWorkStructureDigest(chapters: fixture.document.chapters),
            title: fixture.document.title
        )
        let localOnly = DeviceSyncBindingResolution(
            binding: binding,
            descriptor: nil,
            journal: journal,
            allowedEpisodeIDs: [episodeID]
        )
        let remoteReady = DeviceSyncBindingResolution(
            binding: binding,
            descriptor: descriptor,
            journal: journal,
            allowedEpisodeIDs: [episodeID]
        )
        let resolver = LocalFirstBindingSequenceResolver(initial: localOnly, subsequent: remoteReady)
        let signal = AsyncStream<Void>.makeStream()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in try await resolver.resolve() },
                remoteChangeSignals: signal.stream
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let preparation = Task { @MainActor in
            await state.prepareDeviceSync(for: lookup)
        }
        try #require(await resolver.waitUntilInitialLookupIsPaused())

        state.updateEpisodeContent(
            "pending while local only",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        signal.continuation.yield(())
        await resolver.resumeInitialLookup()
        await preparation.value
        for _ in 0 ..< 100 {
            if await server.currentHead(for: EpisodeSyncKey(workID: workID, episodeID: episodeID))?.content
                == "pending while local only" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        signal.continuation.finish()

        #expect(await resolver.lookupCount() >= 2)
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "pending while local only")
        #expect(state.selectedEpisodeID == episodeID)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("新WAL失敗後もpackage本文を保存し古いWALでは巻き戻さない")
    func failedLatestIntentCannotRollBackSavedPackage() async throws {
        let fixture = makeFixture(content: "初期本文")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = FailingDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let identity = try #require(state.activeDeviceSyncIdentity)
        let staleMarker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: state.documentSessionToken),
            documentID: fixture.document.id,
            episodeID: episodeID,
            editorContentGeneration: state.editorContentGeneration,
            mutationSequence: 10,
            createdAt: Date(timeIntervalSince1970: 10),
            replicaID: replicaID,
            localWorkingCopyID: identity.localWorkingCopyID,
            workID: identity.syncKey.workID,
            baseContentDigest: SyncContentDigest(content: fixture.document.episode(episodeID)?.episode.content ?? ""),
            acceptedPriorPackageDigests: [
                SyncContentDigest(content: fixture.document.episode(episodeID)?.episode.content ?? "")
            ],
            content: "古い復旧証拠",
            contentDigest: SyncContentDigest(content: "古い復旧証拠")
        )
        await editIntents.seed(staleMarker)
        await editIntents.failAllSaves()
        state.updateEpisodeContent(
            "packageが保持する新本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        #expect(await state.flushDeviceSyncForBackground())
        let saved = try await repository.load(from: fixture.url)
        #expect(saved.episode(episodeID)?.episode.content == "packageが保持する新本文")
        #expect(state.deviceSyncLocalDurabilityState == .failed)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: fixture.url))
        try await relaunched.prepareDeviceSync(for: #require(relaunched.currentDeviceSyncLookupIdentity))
        #expect(relaunched.document.episode(episodeID)?.episode.content == "packageが保持する新本文")
        #expect(relaunched.deviceSyncLocalDurabilityState == .failed)
        #expect(await editIntents.markers() == [staleMarker])
    }

    @Test("入力時に永続化済みのWALをpublishが再利用してjournalとremoteまで確定する")
    func publishReusesPersistedInputIntent() async throws {
        let fixture = makeFixture(content: "initial")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution },
                editIntentStore: editIntents
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        state.updateEpisodeContent(
            "latest input",
            for: episodeID,
            in: chapterID,
            expectedSession: lookup.documentSession,
            expectedEditorContentGeneration: lookup.editorContentGeneration
        )
        #expect(await state.flushPendingDeviceSyncEditIntents())
        let persisted = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID
        )
        let persistedMarker = try #require(persisted.marker)
        #expect(persistedMarker.content == "latest input")

        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        await state.publishDeviceSyncDraft(content: "latest input", expectedLookup: lookup)

        let key = EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        let package = try await repository.load(from: fixture.url)
        let record = try #require(await journal.storedRecord(for: key))
        let settled = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: persistedMarker.workingCopyIdentity,
            documentID: persistedMarker.documentID,
            episodeID: persistedMarker.episodeID
        )
        #expect(package.episode(episodeID)?.episode.content == "latest input")
        #expect(record.localHead.content == "latest input")
        #expect(await server.currentHead(for: key)?.content == "latest input")
        #expect(settled.marker == nil)
        #expect(state.deviceSyncLocalDurabilityState == .saved)
    }

    @Test("WAL一時失敗は追加入力なしの次回保存でjournalまで再試行する")
    func transientIntentFailureRetriesLatestBodyOnNextSave() async throws {
        let fixture = makeFixture(content: "初期本文")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = FailingDeviceSyncEditIntentStore()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution },
                editIntentStore: editIntents
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        // The immediate WAL worker and the debounced draft retry both fail.
        // The following background save is therefore the first successful retry.
        await editIntents.failNextSaves(2)
        state.updateEpisodeContent(
            "一度失敗した最新本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        await state.deviceSyncDraftTask?.value
        #expect(state.deviceSyncLocalDurabilityState == .failed)

        #expect(await state.flushDeviceSyncForBackground())
        let package = try await repository.load(from: fixture.url)
        let record = try #require(await journal.storedRecord(
            for: EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        ))
        #expect(package.episode(episodeID)?.episode.content == "一度失敗した最新本文")
        #expect(record.localHead.content == "一度失敗した最新本文")
        #expect(await editIntents.markers().isEmpty)
        #expect(state.deviceSyncLocalDurabilityState == .saved)
    }

    @Test("同じ話の重複refreshは一つのremote検査へ合流する")
    func duplicateRefreshJoinsSingleRemoteInspection() async throws {
        let fixture = makeFixture(content: "R0")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let server = InMemoryEpisodeSyncServer()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
        )
        let resolver = PausableCountingDeviceSyncBindingResolver(resolution: resolution)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in await resolver.resolve() }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        try await state.prepareDeviceSync(for: lookup)
        state.updateEpisodeContent(
            "R1",
            for: episodeID,
            in: chapterID,
            expectedSession: lookup.documentSession,
            expectedEditorContentGeneration: lookup.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        await state.publishDeviceSyncDraft(content: "R1", expectedLookup: lookup)
        #expect(state.deviceSyncState == .writer)

        let initialLookupCount = await resolver.lookupCount()
        await resolver.pauseNextLookup()
        let first = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        try #require(await resolver.waitUntilLookupIsPaused())
        let second = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        await Task.yield()

        #expect(await resolver.lookupCount() == initialLookupCount + 1)
        await resolver.resumePausedLookup()
        await first.value
        await second.value

        #expect(await resolver.lookupCount() == initialLookupCount + 1)
        #expect(state.deviceSyncState == .writer)
    }

    @Test("旧claim応答は離脱後に再取得したauthorityを解放しない")
    func staleClaimCannotReleaseAuthorityAfterReselection() async throws {
        let fixture = makeFixture(content: "shared")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let workID = SyncWorkID()
        let server = InMemoryEpisodeSyncServer()
        let firstRepository = DeviceSyncAppRepository()
        let secondRepository = DeviceSyncAppRepository()
        let firstURL = packageURL("claim-race-first")
        let secondURL = packageURL("claim-race-second")
        await firstRepository.seed(fixture.document, at: firstURL)
        await secondRepository.seed(fixture.document, at: secondURL)
        let firstResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let secondResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let firstState = makeState(
            repository: firstRepository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in firstResolution }
            )
        )
        let secondReplicaID = SyncReplicaID()
        let secondEditIntents = InMemoryDeviceSyncEditIntentStore()
        let secondState = makeState(
            repository: secondRepository,
            runtime: DeviceSyncRuntime(
                replicaID: secondReplicaID,
                transport: server,
                binding: { _, _ in secondResolution },
                editIntentStore: secondEditIntents
            )
        )
        #expect(await firstState.openDocument(at: firstURL))
        let firstLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        try await firstState.prepareDeviceSync(for: firstLookup)
        for content in ["temporary first edit", "shared"] {
            firstState.updateEpisodeContent(
                content,
                for: episodeID,
                in: chapterID,
                expectedSession: firstLookup.documentSession,
                expectedEditorContentGeneration: firstLookup.editorContentGeneration
            )
        }
        firstState.deviceSyncDraftTask?.cancel()
        firstState.deviceSyncDraftTask = nil
        await firstState.publishDeviceSyncDraft(content: "shared", expectedLookup: firstLookup)
        #expect(await secondState.openDocument(at: secondURL))
        let secondLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        try await secondState.prepareDeviceSync(for: secondLookup)
        #expect(firstState.deviceSyncState == .writer)
        #expect(secondState.deviceSyncState == .readOnly)

        let firstIdentity = try #require(firstState.activeDeviceSyncIdentity)
        let firstClient = try #require(firstState.deviceSyncClient(for: firstIdentity))
        _ = try await firstClient.coordinator.releaseEditingAuthority()

        await server.pauseNextClaim()
        secondState.updateEpisodeContent(
            "second local edit",
            for: episodeID,
            in: chapterID,
            expectedSession: secondLookup.documentSession,
            expectedEditorContentGeneration: secondLookup.editorContentGeneration
        )
        secondState.deviceSyncDraftTask?.cancel()
        secondState.deviceSyncDraftTask = nil
        let stalePublish = Task { @MainActor in
            await secondState.publishDeviceSyncDraft(content: "second local edit", expectedLookup: secondLookup)
        }
        let reachedClaim = await waitUntilDeviceSyncClaimIsPaused(on: server)
        try #require(reachedClaim)

        #expect(await secondState.selectProjectSectionAfterDeviceSyncDeparture(.settings))
        #expect(await secondState.selectProjectSectionAfterDeviceSyncDeparture(.structure))
        let reselectionLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        let reselection = Task { @MainActor in
            await secondState.prepareDeviceSync(for: reselectionLookup)
        }
        await Task.yield()
        #expect(await server.currentLease(for: firstIdentity.syncKey) == nil)

        await server.resumePausedClaim()
        await stalePublish.value
        await reselection.value

        let currentIdentity = try #require(secondState.activeDeviceSyncIdentity)
        let currentClient = try #require(secondState.deviceSyncClient(for: currentIdentity))
        let didSettle = await waitUntilDeviceSyncSettles(secondState)
        let lease = try #require(await server.currentLease(for: currentIdentity.syncKey))
        let coordinatorState = await currentClient.coordinator.state
        try #require(didSettle)
        let coordinatorContext = try #require({
            if case let .upToDate(context) = coordinatorState {
                return context
            }
            return nil
        }())
        #expect(secondState.deviceSyncState == .writer)
        #expect(secondState.deviceSyncTransferState == .upToDate)
        #expect(coordinatorContext.pendingRevisionCount == 0)
        #expect(coordinatorContext.remoteConfirmation == .confirmed)
        #expect(coordinatorContext.localHead.content == "second local edit")
        #expect(await server.currentHead(for: currentIdentity.syncKey)?.content == "second local edit")
        // D-060では閲覧・再選択だけでは新しいauthorityをclaimしない。同じ
        // working copy/clientに属する保留local editは、停止していた元claimを
        // 完了してよく、そのepochを余分に進めない。
        #expect(lease.authority.epoch == 2)
        #expect(lease.authority.holderReplicaID == secondReplicaID)
        #expect(lease.authority.holderSessionID == currentClient.sessionID)
    }

    @Test("同じ作品IDの別copyはURLごとの明示bindingなしに同期作品へ結合しない")
    func copiedDocumentWithSameDocumentIDRequiresIndependentBinding() async throws {
        let document = NovelDocument.newDocument(title: "copied")
        let firstURL = packageURL("bound-copy")
        let secondURL = packageURL("unbound-copy")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: firstURL)
        await repository.seed(document, at: secondURL)
        let localWorkingCopyID = LocalWorkingCopyID()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            binding: { session, _ in
                guard session.documentURL.standardizedFileURL == firstURL.standardizedFileURL else {
                    return nil
                }
                return resolution
            }
        )
        let state = makeState(repository: repository, runtime: runtime)

        #expect(await state.openDocument(at: firstURL))
        let firstLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: firstLookup)
        #expect(state.activeDeviceSyncIdentity?.localWorkingCopyID == localWorkingCopyID)

        #expect(await state.openDocument(at: secondURL))
        #expect(state.document.id == document.id)
        let secondLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: secondLookup)

        #expect(state.documentSessionToken.documentURL == secondURL.standardizedFileURL)
        #expect(state.activeDeviceSyncIdentity == nil)
        #expect(state.deviceSyncState == .unconfigured)
    }

    @Test("設定画面はEditor未表示でも作品bindingを読み直す")
    func setupStatusRefreshFindsExistingBinding() async throws {
        let fixture = makeFixture(content: "bound")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
        )
        let setup = DeviceSyncSetupRuntime(
            privateWorkingCopyDestination: { _ in nil },
            validatePrivateWorkingCopy: { _ in },
            candidates: { _, _, _ in [] },
            startNew: { _, _, _ in },
            bindExisting: { _, _, _, _, _ in }
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                binding: { _, _ in resolution },
                setup: setup
            )
        )
        #expect(await state.openDocument(at: fixture.url))

        await state.refreshDeviceSyncSetupStatus(expectedSession: state.documentSessionToken)

        #expect(state.deviceSyncSetupState == .configured)
    }

    @Test("同じremote workへ明示bindingした2 copyは別journalで同時にlocal編集できる")
    func twoBoundCopiesUseIndependentJournals() async throws {
        let chapterID = ChapterID()
        let episodeID = EpisodeID()
        let document = NovelDocument(
            title: "two copies",
            chapters: [
                Chapter(
                    id: chapterID,
                    title: "chapter",
                    episodes: [Episode(id: episodeID, content: "shared base")]
                )
            ]
        )
        let firstURL = packageURL("journal-copy-one")
        let secondURL = packageURL("journal-copy-two")
        let firstRepository = DeviceSyncAppRepository()
        let secondRepository = DeviceSyncAppRepository()
        await firstRepository.seed(document, at: firstURL)
        await secondRepository.seed(document, at: secondURL)
        let server = InMemoryEpisodeSyncServer()
        let workID = SyncWorkID()
        let firstJournal = InMemoryEpisodeSyncJournal()
        let secondJournal = InMemoryEpisodeSyncJournal()
        let firstResolution = try makeResolution(
            document: document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: firstJournal
        )
        let secondResolution = try makeResolution(
            document: document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: secondJournal
        )
        let firstState = makeState(
            repository: firstRepository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in firstResolution }
            )
        )
        let secondState = makeState(
            repository: secondRepository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in secondResolution }
            )
        )

        #expect(await firstState.openDocument(at: firstURL))
        let firstLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        try await firstState.prepareDeviceSync(for: firstLookup)
        #expect(await secondState.openDocument(at: secondURL))
        let secondLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        try await secondState.prepareDeviceSync(for: secondLookup)

        let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
        let firstRecord = try #require(await firstJournal.storedRecord(for: key))
        let secondRecord = try #require(await secondJournal.storedRecord(for: key))
        #expect(firstRecord.lease == nil)
        #expect(secondRecord.lease == nil)
        #expect(firstResolution.binding.localWorkingCopyID != secondResolution.binding.localWorkingCopyID)
        #expect(firstState.deviceSyncState == .readOnly)
        #expect(secondState.deviceSyncState == .readOnly)

        await server.setOnline(false)
        firstState.updateEpisodeContent(
            "first offline edit",
            for: episodeID,
            in: chapterID,
            expectedSession: firstLookup.documentSession,
            expectedEditorContentGeneration: firstLookup.editorContentGeneration
        )
        firstState.deviceSyncDraftTask?.cancel()
        firstState.deviceSyncDraftTask = nil
        await firstState.publishDeviceSyncDraft(content: "first offline edit", expectedLookup: firstLookup)

        secondState.updateEpisodeContent(
            "second offline edit",
            for: episodeID,
            in: chapterID,
            expectedSession: secondLookup.documentSession,
            expectedEditorContentGeneration: secondLookup.editorContentGeneration
        )
        secondState.deviceSyncDraftTask?.cancel()
        secondState.deviceSyncDraftTask = nil
        await secondState.publishDeviceSyncDraft(content: "second offline edit", expectedLookup: secondLookup)

        let firstEdited = try #require(await firstJournal.storedRecord(for: key))
        let secondEdited = try #require(await secondJournal.storedRecord(for: key))
        #expect(firstEdited.localHead.content == "first offline edit")
        #expect(secondEdited.localHead.content == "second offline edit")
        #expect(firstEdited.localWorkingCopyID == firstResolution.binding.localWorkingCopyID)
        #expect(secondEdited.localWorkingCopyID == secondResolution.binding.localWorkingCopyID)
        #expect(firstState.deviceSyncState == .offlineLocal)
        #expect(secondState.deviceSyncState == .offlineLocal)
        let firstEditedLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        let secondEditedLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        #expect(firstState.deviceSyncAllowsEditing(for: firstEditedLookup))
        #expect(secondState.deviceSyncAllowsEditing(for: secondEditedLookup))
        #expect(await server.currentHead(for: key) == nil)
    }

    @Test("明示binding後の構造変更でも既存話は同期を継続する")
    func existingEpisodeSurvivesLaterStructureChange() async throws {
        let fixture = makeFixture(content: "local")
        let incompatible = NovelDocument(
            id: fixture.document.id,
            title: fixture.document.title,
            chapters: fixture.document.chapters + [Chapter(title: "new chapter", episodes: [])]
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: incompatible,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                binding: { _, _ in resolution }
            )
        )

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)

        #expect(state.deviceSyncState == .readOnly)
        #expect(state.activeDeviceSyncIdentity?.episodeID == fixture.document.chapters[0].episodes[0].id)
        #expect(state.deviceSyncAllowsEditing(for: lookup))

        let episodeID = fixture.document.chapters[0].episodes[0].id
        let chapterID = fixture.document.chapters[0].id
        state.updateEpisodeContent(
            "local after structure change",
            for: episodeID,
            in: chapterID,
            expectedSession: lookup.documentSession,
            expectedEditorContentGeneration: lookup.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        await state.publishDeviceSyncDraft(content: "local after structure change", expectedLookup: lookup)

        #expect(state.deviceSyncState == .writer)
    }

    @Test("旧sealed再送後に残る最新tailも入力停止中に送信する")
    func publishRetriesTailAfterInterruptedSealedBatch() async throws {
        let fixture = makeFixture(content: "initial")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let workID = SyncWorkID()
        let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        #expect(state.deviceSyncState == .readOnly)

        await server.cancelNextPublish()
        state.updateEpisodeContent(
            "first sealed",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        await state.deviceSyncDraftTask?.value
        let interrupted = try #require(await journal.storedRecord(for: key))
        #expect(interrupted.sealedPublish != nil)

        state.updateEpisodeContent(
            "latest tail",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        let latestDraft = try #require(state.deviceSyncDraftTask)
        await latestDraft.value

        let remote = try #require(await server.currentHead(for: key))
        let settled = try #require(await journal.storedRecord(for: key))
        #expect(remote.content == "latest tail")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(settled.sealedPublish == nil)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("通信が停止中でもbackground保存は待たずに最新IME本文をpackageへ残す")
    func backgroundFlushDoesNotWaitForPausedPublish() async throws {
        let fixture = makeFixture(content: "initial")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let journal = InMemoryEpisodeSyncJournal()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let committedText = "通信中にIMEで確定した最新本文"
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            ),
            activeCommittedTextCapture: { .captured(committedText) }
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        #expect(state.deviceSyncState == .readOnly)

        await server.pauseNextPublish()
        state.updateEpisodeContent(
            "送信中の旧本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        try #require(await waitUntilDeviceSyncPublishIsPaused(on: server))

        let flush = Task { @MainActor in
            await state.flushDeviceSyncForBackground()
        }
        try await Task.sleep(for: .milliseconds(100))
        let savedBeforeNetworkResumed = try await repository.load(from: fixture.url)
        #expect(savedBeforeNetworkResumed.episode(episodeID)?.episode.content == committedText)
        let key = EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        let durableTail = try #require(await journal.storedRecord(for: key))
        #expect(durableTail.localHead.content == committedText)
        #expect(durableTail.pendingRevisions.contains { $0.content == committedText })

        await server.resumePausedPublish()
        #expect(await flush.value)
        try await Task.sleep(for: .milliseconds(100))
        let retainedTail = try #require(await journal.storedRecord(for: durableTail.key))
        #expect(retainedTail.localHead.content == committedText)
    }

    @Test("packageだけ先行した本文はauthority再取得時にjournalとremoteへ反映する")
    func verifiedAuthorityReplaysPackageAheadContent() async throws {
        let fixture = makeFixture(content: "R0")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let identity = try #require(state.activeDeviceSyncIdentity)
        let client = try #require(state.deviceSyncClient(for: identity))

        state.updateEpisodeContent(
            "X package ahead",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        #expect(await state.saveNow())
        let before = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(before.localHead.content == "R0")

        _ = try await client.coordinator.releaseEditingAuthority()
        await state.refreshSelectedEpisodeDeviceSync()

        let remote = try #require(await server.currentHead(for: identity.syncKey))
        let settled = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(remote.content == "X package ahead")
        #expect(settled.localHead.content == "X package ahead")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(state.deviceSyncState == .writer)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("停止中の古いfence応答は新しいdraft publishを巻き戻さない")
    func staleFenceResponseCannotRollBackDraftPublish() async throws {
        let fixture = makeFixture(content: "R0")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let identity = try #require(state.activeDeviceSyncIdentity)

        await server.pauseNextSnapshotResponseAfterCapture()
        let refresh = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        try #require(await waitUntilDeviceSyncSnapshotResponseIsPaused(on: server))

        state.updateEpisodeContent(
            "R1",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        let draft = try #require(state.deviceSyncDraftTask)
        for _ in 0 ..< 100 {
            if await journal.storedRecord(for: identity.syncKey)?.localHead.content == "R1" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let durableTail = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(durableTail.localHead.content == "R1")
        // clean openはremoteへ基準本文をpublishしない。停止中snapshotがnilでも、
        // その後の明示編集R1はjournalから安全に送信できる。
        #expect(await server.currentHead(for: identity.syncKey) == nil)

        await server.resumePausedSnapshotResponse()
        await refresh.value
        await draft.value

        let settled = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(await server.currentHead(for: identity.syncKey)?.content == "R1")
        #expect(settled.localHead.content == "R1")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(state.document.episode(episodeID)?.episode.content == "R1")
        #expect(state.deviceSyncState == .writer)
    }

    @Test("競合choiceのpackage・journal確定後に終了しても再起動が自動publish・cleanupする")
    func materializedConflictChoiceResumesAfterRelaunchBeforeRemotePublish() async throws {
        let episodeID = EpisodeID()
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let now = Date(timeIntervalSince1970: 9000)
        let remoteWriter = EpisodeSyncCoordinator(
            key: key,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        _ = try await remoteWriter.link(
            localContent: "remote body",
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        let remote = try #require(await server.currentHead(for: key))
        let localWorkingCopyID = LocalWorkingCopyID()
        let local = try EpisodeRevision(
            key: key,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: "local accepted body",
            clientCreatedAt: now.addingTimeInterval(1)
        )
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)
        let journal = InMemoryEpisodeSyncJournal()
        try await journal.save(EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            branchID: local.branchID,
            lastKnownRemoteHead: remote,
            localHead: local,
            pendingRevisions: [local],
            conflict: conflict,
            mode: .forcedFork
        ))
        let chapterID = ChapterID()
        let document = NovelDocument(
            title: "generic conflict recovery",
            chapters: [Chapter(
                id: chapterID,
                title: "chapter",
                episodes: [Episode(id: episodeID, content: local.content)]
            )]
        )
        let url = packageURL("generic-conflict-choice-relaunch")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: key.workID,
            journal: journal
        )
        let mergeRecoveryStore = InMemoryDeviceSyncMergeRecoveryStore()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            mergeRecoveryStore: mergeRecoveryStore,
            now: { now.addingTimeInterval(10) },
            leaseDuration: 600
        )
        let firstState = makeState(
            repository: repository,
            runtime: runtime,
            activeCommittedTextCapture: { .captured(local.content) }
        )
        #expect(await firstState.openDocument(at: url))
        try await firstState.prepareDeviceSync(for: #require(firstState.currentDeviceSyncLookupIdentity))
        let presented = try #require(firstState.deviceSyncConflict)
        #expect(presented == conflict)
        await server.pauseNextPublish()
        await firstState.resolveDeviceSyncConflict(using: .keepLocal, expectedConflict: presented)
        try #require(await waitUntilDeviceSyncPublishIsPaused(on: server))
        let interruptedIdentity = try #require(firstState.activeDeviceSyncIdentity)
        let interruptedClient = try #require(firstState.deviceSyncClient(for: interruptedIdentity))
        let materialized = try #require(await journal.storedRecord(for: key))
        let chosen = try #require(materialized.stagedConflictResolution)
        #expect(chosen.content == local.content)
        #expect(Set(chosen.parentRevisionIDs) == Set([local.revisionID, remote.revisionID]))
        #expect(materialized.conflict == nil)
        #expect(materialized.conflictResolutionRecovery?.chosenRevision == chosen)
        let saved = try await repository.load(from: url)
        #expect(saved.episode(episodeID)?.episode.content == local.content)
        #expect(await server.currentHead(for: key) == remote)
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)
        // packageとjournalの確定直後にprocessが終了し、旧publishはcommitしない。
        await server.setOnline(false)
        await server.resumePausedPublish()
        try #require(await waitUntilDeviceSyncCoordinatorStopsSynchronizing(interruptedClient.coordinator))
        #expect(await server.currentHead(for: key) == remote)
        await server.setOnline(true)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: url))
        try await relaunched.prepareDeviceSync(for: #require(relaunched.currentDeviceSyncLookupIdentity))
        var didRecover = false
        for _ in 0 ..< 2000 {
            let head = await server.currentHead(for: key)
            let stored = await journal.storedRecord(for: key)
            if head?.revisionID == chosen.revisionID,
               stored?.localHead.revisionID == chosen.revisionID,
               stored?.pendingRevisions.isEmpty == true,
               stored?.stagedConflictResolution == nil,
               stored?.conflictResolutionRecovery == nil {
                didRecover = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(didRecover)
        let recoveredHead = try #require(await server.currentHead(for: key))
        #expect(recoveredHead.content == local.content)
        #expect(Set(recoveredHead.parentRevisionIDs) == Set([local.revisionID, remote.revisionID]))
        #expect(relaunched.document.episode(episodeID)?.episode.content == local.content)
        #expect(relaunched.deviceSyncConflict == nil)
        #expect(relaunched.pendingDeviceSyncConflictResolution == nil)
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)
    }

    @Test("競合中の追加localとremote raceを保持した2-parent mergeだけを公開する")
    func conflictForceRacePreservesLatestLocalChain() async throws {
        let episodeID = EpisodeID()
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let writerJournal = InMemoryEpisodeSyncJournal()
        let writer = EpisodeSyncCoordinator(
            key: key,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: writerJournal
        )
        let now = Date(timeIntervalSince1970: 10000)
        _ = try await writer.link(
            localContent: "B remote",
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        let remoteB = try #require(await server.currentHead(for: key))

        let appJournal = InMemoryEpisodeSyncJournal()
        let localA = try EpisodeRevision(
            key: key,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: "A local fork",
            clientCreatedAt: now.addingTimeInterval(1)
        )
        let originalConflict = EpisodeConflict(base: nil, local: localA, remote: remoteB)
        let localWorkingCopyID = LocalWorkingCopyID()
        try await appJournal.save(
            EpisodeSyncJournalRecord(
                key: key,
                localWorkingCopyID: localWorkingCopyID,
                branchID: localA.branchID,
                lastKnownRemoteHead: remoteB,
                localHead: localA,
                pendingRevisions: [localA],
                conflict: originalConflict,
                mode: .forcedFork
            )
        )

        let chapterID = ChapterID()
        let document = NovelDocument(
            title: "conflict",
            chapters: [
                Chapter(
                    id: chapterID,
                    title: "chapter",
                    episodes: [Episode(id: episodeID, content: "X package-only draft")]
                )
            ]
        )
        let url = packageURL("conflict-force-race")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: key.workID,
            journal: appJournal
        )
        let mergeRecoveryStore = InMemoryDeviceSyncMergeRecoveryStore()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in
                resolution
            },
            mergeRecoveryStore: mergeRecoveryStore,
            now: { now.addingTimeInterval(10) },
            leaseDuration: 600
        )
        let state = makeState(
            repository: repository,
            runtime: runtime,
            activeCommittedTextCapture: { .captured("X package-only draft") }
        )
        #expect(await state.openDocument(at: url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        let presentedConflict = try #require(state.deviceSyncConflict)
        // D-060ではpackageに先行していたXも失わず、元local Aの子revisionとして
        // journalへ昇格してから利用者へ提示する。
        #expect(presentedConflict.local.content == "X package-only draft")
        #expect(presentedConflict.local.parentRevisionIDs == [localA.revisionID])
        #expect(presentedConflict.remote == originalConflict.remote)
        #expect(state.document.episode(episodeID)?.episode.content == "X package-only draft")
        #expect(state.pendingDeviceSyncConflictResolution == nil)

        _ = try await writer.recordLocalContent("C raced remote", createdAt: now.addingTimeInterval(2))
        _ = try await writer.synchronize()
        let remoteC = try #require(await server.currentHead(for: key))
        #expect(remoteC.content == "C raced remote")

        await state.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: presentedConflict
        )

        var observedRemoteRace = false
        for _ in 0 ..< 2000 {
            if state.deviceSyncConflict?.remote.revisionID == remoteC.revisionID {
                observedRemoteRace = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(observedRemoteRace)
        let rebasedConflict = try #require(state.deviceSyncConflict)
        // 最初にmaterializeしたXのmerge revisionもremoteへ未送信のlocal chainであり、
        // Cとの再競合ではそのrevision自体を次のdirect parentとして保持する。
        #expect(rebasedConflict.local.content == presentedConflict.local.content)
        #expect(Set(rebasedConflict.local.parentRevisionIDs) == Set([
            presentedConflict.local.revisionID,
            remoteB.revisionID
        ]))
        #expect(rebasedConflict.remote.revisionID == remoteC.revisionID)
        #expect(state.pendingDeviceSyncConflictResolution?.content == presentedConflict.local.content)
        let loadedRebasedMarker = await mergeRecoveryStore.load(
            localWorkingCopyID: localWorkingCopyID,
            key: key
        )
        // tap直後の外部bridgeはdomain journalへchoiceをstageした時点で削除済み。
        #expect(loadedRebasedMarker == nil)
        await server.pauseNextPublish()
        await state.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: rebasedConflict
        )
        try #require(await waitUntilDeviceSyncPublishIsPaused(on: server))
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)

        // The external marker is only the tap-to-domain-stage bridge. Once the
        // staged choice is journal-durable it must already be gone, so remote
        // acknowledgement can finish after this editor surface departs.
        #expect(await state.selectProjectSectionAfterDeviceSyncDeparture(.settings))
        await server.resumePausedPublish()
        var didPublishFinalMerge = false
        for _ in 0 ..< 2000 {
            let remote = await server.currentHead(for: key)
            let record = await appJournal.storedRecord(for: key)
            if remote?.content == presentedConflict.local.content,
               remote?.revisionID == record?.localHead.revisionID,
               record?.pendingRevisions.isEmpty == true,
               record?.conflict == nil {
                didPublishFinalMerge = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(didPublishFinalMerge)

        let mergedHead = try #require(await server.currentHead(for: key))
        #expect(mergedHead.content == presentedConflict.local.content)
        #expect(Set(mergedHead.parentRevisionIDs) == Set([
            rebasedConflict.local.revisionID,
            remoteC.revisionID
        ]))
        #expect(!mergedHead.parentRevisionIDs.contains(remoteB.revisionID))
        #expect(state.document.episode(episodeID)?.episode.content == presentedConflict.local.content)
        #expect(state.deviceSyncConflict == nil)
        let storedRecord = try #require(await appJournal.storedRecord(for: key))
        #expect(storedRecord.conflict == nil)
        #expect(storedRecord.localHead.revisionID == mergedHead.revisionID)
        #expect(storedRecord.pendingRevisions.isEmpty)
        #expect(storedRecord.stagedConflictResolution == nil)
        #expect(storedRecord.conflictResolutionRecovery == nil)
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)

        // Relaunching after a relay/tail publish must never resurrect the old
        // accepted body as a future review draft.
        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: url))
        try await relaunched.prepareDeviceSync(for: #require(relaunched.currentDeviceSyncLookupIdentity))
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)
        #expect(relaunched.pendingDeviceSyncConflictResolution == nil)
        #expect(relaunched.deviceSyncConflict == nil)
    }

    private func assertWorkConflictChoicePreservesPackageTail(
        successfulSavesBeforeFailure: Int
    ) async throws {
        let fixture = makeFixture(content: "競合中の本文")
        var baseDocument = fixture.document
        baseDocument.title = "共通作品名"
        var localDocument = fixture.document
        localDocument.title = "このMacの競合版"
        var remoteDocument = fixture.document
        remoteDocument.title = "iCloudの競合版"
        let workID = SyncWorkID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let journal = FailingWorkSyncJournal()
        try await journal.save(conflictedWorkRecord(
            baseDocument: baseDocument,
            localDocument: localDocument,
            remoteDocument: remoteDocument,
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID
        ))
        let episodeIDs = Set(localDocument.chapters.flatMap(\.episodes).map(\.id))
        let resolution = DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: nil,
            journal: InMemoryEpisodeSyncJournal(),
            workJournal: journal,
            allowedEpisodeIDs: episodeIDs,
            remoteAvailability: .configurationBlocked
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(localDocument, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: InMemoryEpisodeSyncServer(),
                workTransport: CountingWorkSyncTransport(),
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let oldReview = try #require(state.workSyncConflictReview)
        await journal.failSaves(
            afterSuccessfulSaves: successfulSavesBeforeFailure,
            count: 2
        )

        state.updateDocumentTitle("競合表示後に追記したtail")
        await state.resolveWorkSyncConflict(
            using: .keepRemote,
            expectedReview: oldReview,
            expectedSession: state.documentSessionToken
        )

        #expect(try await repository.load(from: fixture.url).title == "競合表示後に追記したtail")
        #expect(state.workSyncConflictReview == oldReview)
        #expect(state.deviceSyncLocalDurabilityState == .savedSyncPreparationFailed)
        #expect(await journal.storedRecord(for: workID)?.conflictReview == oldReview)

        // journalが復旧した同じ旧choiceはtailを取り込んだreviewへ更新するだけで、
        // その場では適用しない。
        await state.resolveWorkSyncConflict(
            using: .keepRemote,
            expectedReview: oldReview,
            expectedSession: state.documentSessionToken
        )
        let refreshedReview = try #require(state.workSyncConflictReview)
        #expect(refreshedReview != oldReview)
        #expect(refreshedReview.local.snapshot.title == "競合表示後に追記したtail")
        #expect(try await repository.load(from: fixture.url).title == "競合表示後に追記したtail")
        #expect(await journal.storedRecord(for: workID)?.stagedLocalRevision == nil)
        #expect(state.deviceSyncLocalDurabilityState == .saved)

        // 更新後の比較を見て選び直したchoiceだけをmaterializeする。
        await state.resolveWorkSyncConflict(
            using: .keepLocal,
            expectedReview: refreshedReview,
            expectedSession: state.documentSessionToken
        )
        #expect(try await repository.load(from: fixture.url).title == "競合表示後に追記したtail")
        #expect(state.workSyncConflictReview == nil)
        #expect(await journal.storedRecord(for: workID)?.conflictReview == nil)
    }

    private func pendingRemoteWorkRecord(
        baseDocument: NovelDocument,
        remoteDocument: NovelDocument,
        workID: SyncWorkID,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID
    ) throws -> WorkSyncJournalRecord {
        let branchID = SyncBranchID()
        let base = try workRevision(
            document: baseDocument,
            workID: workID,
            branchID: branchID,
            replicaID: replicaID,
            parents: [],
            timestamp: 1
        )
        let remote = try workRevision(
            document: remoteDocument,
            workID: workID,
            branchID: branchID,
            replicaID: SyncReplicaID(),
            parents: [base.revisionID],
            timestamp: 2
        )
        return try WorkSyncJournalRecord(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: remote,
            localHead: base,
            outbox: [],
            pendingRemoteMaterialization: WorkPendingMaterialization(
                kind: .remoteFastForward,
                sourceLocalRevisionID: base.revisionID,
                revision: remote
            ),
            reconciliationStatus: .materializationRequired
        )
    }

    private func conflictedWorkRecord(
        baseDocument: NovelDocument,
        localDocument: NovelDocument,
        remoteDocument: NovelDocument,
        workID: SyncWorkID,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID
    ) throws -> WorkSyncJournalRecord {
        let branchID = SyncBranchID()
        let base = try workRevision(
            document: baseDocument,
            workID: workID,
            branchID: branchID,
            replicaID: replicaID,
            parents: [],
            timestamp: 1
        )
        let local = try workRevision(
            document: localDocument,
            workID: workID,
            branchID: branchID,
            replicaID: replicaID,
            parents: [base.revisionID],
            timestamp: 2
        )
        let remote = try workRevision(
            document: remoteDocument,
            workID: workID,
            branchID: branchID,
            replicaID: SyncReplicaID(),
            parents: [base.revisionID],
            timestamp: 3
        )
        let review = try WorkConflictReview(
            base: base,
            local: local,
            remote: remote,
            proposedSnapshot: local.snapshot,
            conflicts: [
                WorkFieldConflict(
                    path: "document.title",
                    entityKind: .document,
                    entityID: nil,
                    field: "title",
                    reason: .sameFieldChanged,
                    baseValue: baseDocument.title,
                    localValue: localDocument.title,
                    remoteValue: remoteDocument.title,
                    proposedValue: localDocument.title
                )
            ]
        )
        return try WorkSyncJournalRecord(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: remote,
            localHead: local,
            outbox: [local],
            conflictReview: review,
            reconciliationStatus: .reviewRequired
        )
    }

    private func workRevision(
        document: NovelDocument,
        workID: SyncWorkID,
        branchID: SyncBranchID,
        replicaID: SyncReplicaID,
        parents: [SyncRevisionID],
        timestamp: TimeInterval
    ) throws -> WorkRevision {
        try WorkRevision(
            workID: workID,
            parentRevisionIDs: parents,
            branchID: branchID,
            authorReplicaID: replicaID,
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: document),
            clientCreatedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func makeState(
        repository: DeviceSyncAppRepository,
        runtime: DeviceSyncRuntime? = nil,
        activeCommittedTextCapture: (@MainActor () -> EditorCommittedTextCaptureResult)? = nil
    ) -> AppState {
        let suiteName = "FUMINIWA.DeviceSyncAppIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                activeCommittedTextCapture: activeCommittedTextCapture,
                deviceSyncRuntime: runtime
            ),
            initialStartupState: .ready
        )
    }

    private func waitUntilDeviceSyncClaimIsPaused(
        on server: InMemoryEpisodeSyncServer
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if await server.claimIsPaused() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncPublishIsPaused(
        on server: InMemoryEpisodeSyncServer
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if await server.publishIsPaused() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncSnapshotResponseIsPaused(
        on server: InMemoryEpisodeSyncServer
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if await server.snapshotResponseIsPaused() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncSettles(_ state: AppState) async -> Bool {
        for _ in 0 ..< 2000 {
            if state.deviceSyncState != .syncing, state.deviceSyncState != .forcing {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncCoordinatorStopsSynchronizing(
        _ coordinator: EpisodeSyncCoordinator
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if case .synchronizing = await coordinator.state {
                try? await Task.sleep(for: .milliseconds(1))
            } else {
                return true
            }
        }
        return false
    }

    private func makeFixture(content: String) -> (document: NovelDocument, url: URL) {
        let document = NovelDocument(
            title: "fixture",
            chapters: [Chapter(title: "chapter", episodes: [Episode(content: content)])]
        )
        return (document, packageURL("fixture-\(UUID().uuidString)"))
    }

    private func makeResolution(
        document: NovelDocument,
        localWorkingCopyID: LocalWorkingCopyID,
        workID: SyncWorkID,
        journal: any EpisodeSyncJournal,
        workJournal: (any WorkSyncJournal)? = nil,
        remoteAvailability: DeviceSyncRemoteAvailability? = nil
    ) throws -> DeviceSyncBindingResolution {
        try DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: workID,
                sourceDocumentID: document.id,
                structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                title: document.title
            ),
            journal: journal,
            workJournal: workJournal,
            allowedEpisodeIDs: Set(document.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: remoteAvailability
        )
    }

    private func sharedWorkJournalRecord(
        base: WorkRevision,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID
    ) throws -> WorkSyncJournalRecord {
        try WorkSyncJournalRecord(
            workID: base.workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: base.branchID,
            lastKnownRemoteHead: base,
            localHead: base,
            outbox: [],
            reconciliationStatus: .synchronized
        )
    }

    private func waitForWorkSyncNetwork(_ state: AppState) async {
        while let task = state.workSyncNetworkTask {
            await task.value
        }
    }

    private func revision(
        key: EpisodeSyncKey,
        parents: [SyncRevisionID],
        content: String
    ) throws -> EpisodeRevision {
        try EpisodeRevision(
            key: key,
            parentRevisionIDs: parents,
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: content,
            clientCreatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func editIntentMarker(
        content: String,
        sequence: UInt64,
        documentID: UUID = UUID(),
        episodeID: EpisodeID = EpisodeID()
    ) -> DeviceSyncEditIntentMarker {
        DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: "test-working-copy",
            documentID: documentID,
            episodeID: episodeID,
            editorContentGeneration: sequence,
            mutationSequence: sequence,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: nil,
            acceptedPriorPackageDigests: nil,
            content: content,
            contentDigest: SyncContentDigest(content: content)
        )
    }

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-DeviceSync-App-Tests", isDirectory: true)
            .appendingPathComponent("\(name).novelpkg", isDirectory: true)
    }
}

private actor DeviceSyncAppRepository: DocumentRepository {
    private var documents: [String: NovelDocument] = [:]
    private var saveObserver: (@Sendable (NovelDocument) async -> Void)?
    private var shouldPauseNextSave = false
    private var shouldFailNextSave = false
    private var pausedSaveContinuation: CheckedContinuation<Void, Never>?
    private var nextSavedDocumentOverride: NovelDocument?

    func seed(_ document: NovelDocument, at url: URL) {
        documents[url.standardizedFileURL.path] = document
    }

    func load(from url: URL) async throws -> NovelDocument {
        guard let document = documents[url.standardizedFileURL.path] else {
            throw DeviceSyncAppRepositoryError.missingDocument
        }
        return document
    }

    func save(_ document: NovelDocument, to url: URL) async throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw DeviceSyncAppRepositoryError.injectedPackageSaveFailure
        }
        if let nextSavedDocumentOverride {
            documents[url.standardizedFileURL.path] = nextSavedDocumentOverride
            self.nextSavedDocumentOverride = nil
        } else {
            documents[url.standardizedFileURL.path] = document
        }
        if shouldPauseNextSave {
            shouldPauseNextSave = false
            await withCheckedContinuation { continuation in
                pausedSaveContinuation = continuation
            }
        }
        if let saveObserver {
            await saveObserver(document)
        }
    }

    func pauseNextSave() {
        shouldPauseNextSave = true
    }

    func failNextSave() {
        shouldFailNextSave = true
    }

    func waitUntilSaveIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if pausedSaveContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedSave() {
        pausedSaveContinuation?.resume()
        pausedSaveContinuation = nil
    }

    func setSaveObserver(_ observer: (@Sendable (NovelDocument) async -> Void)?) {
        saveObserver = observer
    }

    func corruptNextSave(with document: NovelDocument) {
        nextSavedDocumentOverride = document
    }
}

private enum WorkSyncTestFailure: Error {
    case injectedJournalFailure
}

@MainActor
private final class WorkSyncCommittedTextCapture {
    var content: String?

    func capture() -> EditorCommittedTextCaptureResult {
        content.map(EditorCommittedTextCaptureResult.captured) ?? .notActive
    }
}

private enum WorkSyncEvent: Equatable, Sendable {
    case journalStage
    case packageSave
    case journalConfirmation
    case network
}

private actor WorkSyncEventTrace {
    private var events: [WorkSyncEvent] = []

    func record(_ event: WorkSyncEvent) {
        events.append(event)
    }

    func reset() {
        events = []
    }

    func snapshot() -> [WorkSyncEvent] {
        events
    }
}

private actor TracingWorkSyncJournal: WorkSyncJournal {
    private let storage = InMemoryWorkSyncJournal()
    private let trace: WorkSyncEventTrace

    init(trace: WorkSyncEventTrace) {
        self.trace = trace
    }

    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        try await storage.load(for: workID)
    }

    func save(_ record: WorkSyncJournalRecord) async throws {
        await trace.record(
            record.stagedLocalRevision == nil ? .journalConfirmation : .journalStage
        )
        try await storage.save(record)
    }
}

private actor TracingWorkSyncTransport: WorkSyncTransport {
    private let server = InMemoryWorkSyncServer()
    private let trace: WorkSyncEventTrace

    init(trace: WorkSyncEventTrace) {
        self.trace = trace
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        await trace.record(.network)
        return try await server.fetchSnapshot(for: workID)
    }

    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision {
        await trace.record(.network)
        return try await server.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        await trace.record(.network)
        return try await server.publish(request)
    }

    func currentHead(for workID: SyncWorkID) async -> WorkRevision? {
        await server.currentHead(for: workID)
    }
}

private actor FailingWorkSyncJournal: WorkSyncJournal {
    private let storage = InMemoryWorkSyncJournal()
    private var successfulSavesBeforeFailure = 0
    private var remainingSaveFailures = 0
    private var shouldPauseNextLoad = false
    private var pausedLoadContinuation: CheckedContinuation<Void, Never>?

    func failNextSave() {
        failSaves(afterSuccessfulSaves: 0, count: 1)
    }

    func failSaves(afterSuccessfulSaves: Int, count: Int) {
        successfulSavesBeforeFailure = afterSuccessfulSaves
        remainingSaveFailures = count
    }

    func pauseNextLoad() {
        shouldPauseNextLoad = true
    }

    func waitUntilLoadIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if pausedLoadContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedLoad() {
        pausedLoadContinuation?.resume()
        pausedLoadContinuation = nil
    }

    func storedRecord(for workID: SyncWorkID) async -> WorkSyncJournalRecord? {
        try? await storage.load(for: workID)
    }

    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        if shouldPauseNextLoad {
            shouldPauseNextLoad = false
            await withCheckedContinuation { continuation in
                pausedLoadContinuation = continuation
            }
        }
        return try await storage.load(for: workID)
    }

    func save(_ record: WorkSyncJournalRecord) async throws {
        if successfulSavesBeforeFailure > 0 {
            successfulSavesBeforeFailure -= 1
        } else if remainingSaveFailures > 0 {
            remainingSaveFailures -= 1
            throw WorkSyncTestFailure.injectedJournalFailure
        }
        try await storage.save(record)
    }
}

private actor CountingWorkSyncTransport: WorkSyncTransport {
    private let server = InMemoryWorkSyncServer()
    private var operations = 0

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        operations += 1
        return try await server.fetchSnapshot(for: workID)
    }

    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision {
        operations += 1
        return try await server.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        operations += 1
        return try await server.publish(request)
    }

    func operationCount() -> Int {
        operations
    }
}

private actor DivergingWorkSyncTransport: WorkSyncTransport {
    private let server = InMemoryWorkSyncServer()
    private var remainingDivergences = 0
    private var observedPublishCount = 0

    func divergeNextPublishes(_ count: Int) {
        remainingDivergences = count
        observedPublishCount = 0
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await server.fetchSnapshot(for: workID)
    }

    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision {
        try await server.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        observedPublishCount += 1
        if remainingDivergences > 0 {
            remainingDivergences -= 1
            let snapshot = try await server.fetchSnapshot(for: request.workID)
            return .diverged(snapshot)
        }
        return try await server.publish(request)
    }

    func currentHead(for workID: SyncWorkID) async -> WorkRevision? {
        await server.currentHead(for: workID)
    }

    func publishCount() -> Int {
        observedPublishCount
    }
}

private actor ConfirmFailureSaveObserver {
    private let episodeID: EpisodeID
    private let localContent: String
    private let remoteContent: String
    private let server: InMemoryEpisodeSyncServer
    private var observedLocalSave = false
    private var didTakeServerOffline = false

    init(
        episodeID: EpisodeID,
        localContent: String,
        remoteContent: String,
        server: InMemoryEpisodeSyncServer
    ) {
        self.episodeID = episodeID
        self.localContent = localContent
        self.remoteContent = remoteContent
        self.server = server
    }

    func observe(_ document: NovelDocument) async {
        guard let content = document.episode(episodeID)?.episode.content else { return }
        if content == localContent {
            observedLocalSave = true
        } else if observedLocalSave, content == remoteContent, !didTakeServerOffline {
            didTakeServerOffline = true
            await server.setOnline(false)
        }
    }

    func didTriggerFailure() -> Bool {
        didTakeServerOffline
    }
}

private actor DelayedDeviceSyncBindingResolver {
    private var lookupCount = 0
    private var firstContinuation: CheckedContinuation<DeviceSyncBindingResolution?, Never>?

    func resolve(_: DocumentSessionToken) async -> DeviceSyncBindingResolution? {
        lookupCount += 1
        guard lookupCount == 1 else { return nil }
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func waitUntilFirstLookupIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if firstContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumeFirstLookup(with resolution: DeviceSyncBindingResolution?) {
        firstContinuation?.resume(returning: resolution)
        firstContinuation = nil
    }

    func observedLookupCount() -> Int {
        lookupCount
    }
}

private actor PausableCountingDeviceSyncBindingResolver {
    private let resolution: DeviceSyncBindingResolution
    private var observedLookups = 0
    private var shouldPauseNextLookup = false
    private var pausedLookupContinuation: CheckedContinuation<Void, Never>?

    init(resolution: DeviceSyncBindingResolution) {
        self.resolution = resolution
    }

    func resolve() async -> DeviceSyncBindingResolution {
        observedLookups += 1
        if shouldPauseNextLookup {
            shouldPauseNextLookup = false
            await withCheckedContinuation { continuation in
                pausedLookupContinuation = continuation
            }
        }
        return resolution
    }

    func pauseNextLookup() {
        shouldPauseNextLookup = true
    }

    func waitUntilLookupIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if pausedLookupContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedLookup() {
        pausedLookupContinuation?.resume()
        pausedLookupContinuation = nil
    }

    func lookupCount() -> Int {
        observedLookups
    }
}

private actor LocalFirstBindingSequenceResolver {
    private let initial: DeviceSyncBindingResolution
    private let subsequent: DeviceSyncBindingResolution
    private var observedLookups = 0
    private var initialContinuation: CheckedContinuation<DeviceSyncBindingResolution, Never>?

    init(initial: DeviceSyncBindingResolution, subsequent: DeviceSyncBindingResolution) {
        self.initial = initial
        self.subsequent = subsequent
    }

    func resolve() async throws -> DeviceSyncBindingResolution {
        observedLookups += 1
        guard observedLookups == 1 else { return subsequent }
        return await withCheckedContinuation { continuation in
            initialContinuation = continuation
        }
    }

    func waitUntilInitialLookupIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if initialContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumeInitialLookup() {
        initialContinuation?.resume(returning: initial)
        initialContinuation = nil
    }

    func lookupCount() -> Int {
        observedLookups
    }
}

private actor FailingDeviceSyncEditIntentStore: DeviceSyncEditIntentStoring {
    private var stored: [DeviceSyncEditIntentMarker] = []
    private var remainingSaveFailures = 0
    private var alwaysFailsSave = false

    func seed(_ marker: DeviceSyncEditIntentMarker) {
        stored = [marker]
    }

    func failNextSaves(_ count: Int) {
        remainingSaveFailures = count
    }

    func failAllSaves() {
        alwaysFailsSave = true
    }

    func save(_ marker: DeviceSyncEditIntentMarker) async throws {
        if alwaysFailsSave || remainingSaveFailures > 0 {
            if remainingSaveFailures > 0 {
                remainingSaveFailures -= 1
            }
            throw DeviceSyncAppRepositoryError.injectedEditIntentFailure
        }
        stored.removeAll {
            $0.workingCopyIdentity == marker.workingCopyIdentity
                && $0.documentID == marker.documentID
                && $0.episodeID == marker.episodeID
        }
        stored.append(marker)
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [DeviceSyncEditIntentMarker] {
        stored.filter {
            $0.workingCopyIdentity == workingCopyIdentity
                && $0.documentID == documentID
                && $0.episodeID == episodeID
        }
    }

    func remove(_ marker: DeviceSyncEditIntentMarker) async throws {
        stored.removeAll { $0 == marker }
    }

    func markers() -> [DeviceSyncEditIntentMarker] {
        stored
    }
}

private actor PausablePreservedRemovalDeviceSyncEditIntentStore: DeviceSyncEditIntentStoring {
    private let storage = InMemoryDeviceSyncEditIntentStore()
    private var shouldPausePreservedRemoval = false
    private var preservedRemovalContinuation: CheckedContinuation<Void, Never>?
    private var shouldPausePreservation = false
    private var preservationContinuation: CheckedContinuation<Void, Never>?
    private var reconcileCounts: [EpisodeID: Int] = [:]
    private var pausedReconcileTarget: (episodeID: EpisodeID, invocation: Int)?
    private var reconcileContinuation: CheckedContinuation<Void, Never>?

    func pauseNextPreservedRemoval() {
        shouldPausePreservedRemoval = true
    }

    func waitUntilPreservedRemovalIsPaused() async -> Bool {
        for _ in 0 ..< 1000 {
            if preservedRemovalContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedPreservedRemoval() {
        preservedRemovalContinuation?.resume()
        preservedRemovalContinuation = nil
    }

    func pauseNextPreservation() {
        shouldPausePreservation = true
    }

    func waitUntilPreservationIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if preservationContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedPreservation() {
        preservationContinuation?.resume()
        preservationContinuation = nil
    }

    func pauseReconcilePreparedPackage(episodeID: EpisodeID, invocation: Int) {
        pausedReconcileTarget = (episodeID, invocation)
    }

    func waitUntilReconcileIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if reconcileContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedReconcile() {
        reconcileContinuation?.resume()
        reconcileContinuation = nil
    }

    func save(_ marker: DeviceSyncEditIntentMarker) async throws {
        try await storage.save(marker)
    }

    func save(
        _ marker: DeviceSyncEditIntentMarker,
        baselinePackageDigest: SyncContentDigest
    ) async throws -> DeviceSyncEditIntentMarker {
        try await storage.save(marker, baselinePackageDigest: baselinePackageDigest)
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [DeviceSyncEditIntentMarker] {
        try await storage.load(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func remove(_ marker: DeviceSyncEditIntentMarker) async throws {
        try await storage.remove(marker)
    }

    func preparePackageSave(_ checkpoint: DeviceSyncPackageCheckpoint) async throws {
        try await storage.preparePackageSave(checkpoint)
    }

    func commitPackageSave(_ checkpoint: DeviceSyncPackageCheckpoint) async throws {
        try await storage.commitPackageSave(checkpoint)
    }

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        try await storage.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func reconcilePreparedPackage(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        actualContentDigest: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        let snapshot = try await storage.reconcilePreparedPackage(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            actualContentDigest: actualContentDigest
        )
        let invocation = (reconcileCounts[episodeID] ?? 0) + 1
        reconcileCounts[episodeID] = invocation
        if let target = pausedReconcileTarget,
           target.episodeID == episodeID,
           target.invocation == invocation {
            pausedReconcileTarget = nil
            await withCheckedContinuation { continuation in
                reconcileContinuation = continuation
            }
        }
        return snapshot
    }

    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence: UInt64,
        contentDigest: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        try await storage.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            throughSequence: throughSequence,
            contentDigest: contentDigest
        )
    }

    func preserveForReview(_ marker: DeviceSyncEditIntentMarker) async throws {
        try await storage.preserveForReview(marker)
        if shouldPausePreservation {
            shouldPausePreservation = false
            await withCheckedContinuation { continuation in
                preservationContinuation = continuation
            }
        }
    }

    func removePreservedForReview(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        expected: [DeviceSyncEditIntentMarker],
        expectedResolvingMarker: DeviceSyncEditIntentMarker
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        if shouldPausePreservedRemoval {
            shouldPausePreservedRemoval = false
            await withCheckedContinuation { continuation in
                preservedRemovalContinuation = continuation
            }
        }
        return try await storage.removePreservedForReview(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            expected: expected,
            expectedResolvingMarker: expectedResolvingMarker
        )
    }
}

private enum DeviceSyncAppRepositoryError: Error {
    case injectedEditIntentFailure
    case injectedPackageSaveFailure
    case missingDocument
    case rejectedPrivateCopy
}
