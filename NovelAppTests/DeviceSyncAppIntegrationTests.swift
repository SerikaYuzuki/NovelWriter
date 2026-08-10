import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSync
import NovelSyncTesting
import Testing

@MainActor
@Suite("Device Sync app integration", .serialized)
struct DeviceSyncAppIntegrationTests {
    @Test("forceは確認要求だけでは開始せず明示確認後に一度だけ開始する")
    func forceContinuationRequiresExplicitConfirmation() {
        var confirmation = DeviceSyncForceContinuationConfirmation()
        var invocationCount = 0

        confirmation.request()
        #expect(confirmation.isPresented)
        #expect(invocationCount == 0)

        confirmation.cancel()
        #expect(!confirmation.isPresented)
        #expect(invocationCount == 0)

        confirmation.request()
        confirmation.confirm {
            invocationCount += 1
        }
        confirmation.confirm {
            invocationCount += 1
        }

        #expect(!confirmation.isPresented)
        #expect(invocationCount == 1)
    }

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
        await resolver.waitUntilFirstLookupIsPaused()

        let secondChapter = document.chapters[1]
        state.selectChapter(secondChapter.id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        #expect(!state.deviceSyncAllowsEditing(for: currentLookup))
        let currentTask = Task { @MainActor in
            await state.prepareDeviceSync(for: currentLookup)
        }
        await Task.yield()
        #expect(await resolver.observedLookupCount() == 1)

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
        await resolver.waitUntilFirstLookupIsPaused()
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

    @Test("同じ話の重複refreshは一つのremote検査へ合流する")
    func duplicateRefreshJoinsSingleRemoteInspection() async throws {
        let fixture = makeFixture(content: "R0")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let server = InMemoryEpisodeSyncServer()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
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
        #expect(state.deviceSyncState == .writer)

        let initialFetchCount = await server.snapshotFetchInvocationCount()
        await server.pauseNextSnapshotResponseAfterCapture()
        let first = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        await server.waitUntilSnapshotResponseIsPaused()
        let second = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        await Task.yield()

        #expect(await server.snapshotFetchInvocationCount() == initialFetchCount + 1)
        await server.resumePausedSnapshotResponse()
        await first.value
        await second.value

        #expect(await server.snapshotFetchInvocationCount() == initialFetchCount + 1)
        #expect(state.deviceSyncState == .writer)
    }

    @Test("旧claim応答は離脱後に再取得したauthorityを解放しない")
    func staleClaimCannotReleaseAuthorityAfterReselection() async throws {
        let fixture = makeFixture(content: "shared")
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
        let secondState = makeState(
            repository: secondRepository,
            runtime: DeviceSyncRuntime(
                replicaID: secondReplicaID,
                transport: server,
                binding: { _, _ in secondResolution }
            )
        )
        #expect(await firstState.openDocument(at: firstURL))
        try await firstState.prepareDeviceSync(for: #require(firstState.currentDeviceSyncLookupIdentity))
        #expect(await secondState.openDocument(at: secondURL))
        try await secondState.prepareDeviceSync(for: #require(secondState.currentDeviceSyncLookupIdentity))
        #expect(firstState.deviceSyncState == .writer)
        #expect(secondState.deviceSyncState == .readOnly)

        let firstIdentity = try #require(firstState.activeDeviceSyncIdentity)
        let firstClient = try #require(firstState.deviceSyncClient(for: firstIdentity))
        _ = try await firstClient.coordinator.releaseEditingAuthority()

        await server.pauseNextClaim()
        let staleRefresh = Task { @MainActor in
            await secondState.refreshSelectedEpisodeDeviceSync()
        }
        await server.waitUntilClaimIsPaused()

        #expect(await secondState.selectProjectSectionAfterDeviceSyncDeparture(.settings))
        #expect(await secondState.selectProjectSectionAfterDeviceSyncDeparture(.structure))
        let reselectionLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        let reselection = Task { @MainActor in
            await secondState.prepareDeviceSync(for: reselectionLookup)
        }
        await Task.yield()
        #expect(await server.currentLease(for: firstIdentity.syncKey) == nil)

        await server.resumePausedClaim()
        await staleRefresh.value
        await reselection.value

        let currentIdentity = try #require(secondState.activeDeviceSyncIdentity)
        let currentClient = try #require(secondState.deviceSyncClient(for: currentIdentity))
        let lease = try #require(await server.currentLease(for: currentIdentity.syncKey))
        #expect(secondState.deviceSyncState == .writer)
        #expect(lease.authority.epoch == 3)
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

    @Test("同じremote workへ明示bindingした2 copyは別journalを使う")
    func twoBoundCopiesUseIndependentJournals() async throws {
        let document = NovelDocument.newDocument(title: "two copies")
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
        try await firstState.prepareDeviceSync(for: #require(firstState.currentDeviceSyncLookupIdentity))
        #expect(await secondState.openDocument(at: secondURL))
        try await secondState.prepareDeviceSync(for: #require(secondState.currentDeviceSyncLookupIdentity))

        let episodeID = try #require(document.chapters.first?.episodes.first?.id)
        let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
        let firstRecord = try #require(await firstJournal.storedRecord(for: key))
        let secondRecord = try #require(await secondJournal.storedRecord(for: key))
        #expect(firstRecord.lease != secondRecord.lease)
        #expect(firstResolution.binding.localWorkingCopyID != secondResolution.binding.localWorkingCopyID)
        #expect(firstState.deviceSyncState == .writer)
        #expect(secondState.deviceSyncState == .readOnly)

        let followerIdentity = try #require(secondState.activeDeviceSyncIdentity)
        let epochBeforeRejectedForce = await server.currentLeaseEpoch(for: key)
        secondState.deviceSyncState = .writer
        await secondState.forceContinueOnThisMac(expectedIdentity: followerIdentity)
        #expect(await server.currentLeaseEpoch(for: key) == epochBeforeRejectedForce)

        secondState.deviceSyncState = .readOnly
        await server.setOnline(false)
        await secondState.refreshSelectedEpisodeDeviceSync()
        #expect(secondState.deviceSyncState == .readOnly)

        await server.setOnline(true)
        let writerIdentity = try #require(firstState.activeDeviceSyncIdentity)
        let writerClient = try #require(firstState.deviceSyncClient(for: writerIdentity))
        _ = try await writerClient.coordinator.releaseEditingAuthority()

        // read-onlyのまま開いている端末は、相手の通常release後の
        // signal/foreground refreshで通常claimし、forceなしでwriterになる。
        await secondState.refreshSelectedEpisodeDeviceSync()
        #expect(secondState.deviceSyncState == .writer)

        let secondWriterIdentity = try #require(secondState.activeDeviceSyncIdentity)
        let secondWriterClient = try #require(secondState.deviceSyncClient(for: secondWriterIdentity))
        _ = try await secondWriterClient.coordinator.releaseEditingAuthority()

        // 同じprocess内に残ったrelease済みclientを再選択しても、
        // 破壊的forceではなく通常claimで再開できる。
        firstState.deviceSyncSelectionDidChange()
        let revisitedLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        await firstState.prepareDeviceSync(for: revisitedLookup)
        #expect(firstState.deviceSyncState == .writer)
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

        #expect(state.deviceSyncState == .writer)
        #expect(state.activeDeviceSyncIdentity?.episodeID == fixture.document.chapters[0].episodes[0].id)
        #expect(state.deviceSyncAllowsEditing(for: lookup))
    }

    @Test("authority confirm再試行はinstall済みremoteでlocal forkを置換しない")
    func authorityConfirmRetryPreservesExistingLocalFork() async throws {
        let fixture = makeFixture(content: "R remote")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let workID = SyncWorkID()
        let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let now = Date(timeIntervalSince1970: 40000)
        let writer = EpisodeSyncCoordinator(
            key: key,
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        _ = try await writer.link(
            localContent: "R remote",
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )

        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let appJournal = InMemoryEpisodeSyncJournal()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: appJournal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            now: { now.addingTimeInterval(10) },
            leaseDuration: 600
        )
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        #expect(state.deviceSyncState == .readOnly)

        state.updateEpisodeContent("X local fork", for: episodeID, in: chapterID)
        let failureTrigger = ConfirmFailureSaveObserver(
            episodeID: episodeID,
            localContent: "X local fork",
            remoteContent: "R remote",
            server: server
        )
        await repository.setSaveObserver { document in
            await failureTrigger.observe(document)
        }

        let forceIdentity = try #require(state.activeDeviceSyncIdentity)
        await state.forceContinueOnThisMac(expectedIdentity: forceIdentity)
        #expect(await failureTrigger.didTriggerFailure())
        let failedRecord = try #require(await appJournal.storedRecord(for: key))
        #expect(failedRecord.pendingRevisions.contains { $0.content == "X local fork" })
        #expect(state.document.episode(episodeID)?.episode.content == "R remote")

        await repository.setSaveObserver(nil)
        await server.setOnline(true)
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))

        let retriedRecord = try #require(await appJournal.storedRecord(for: key))
        #expect(retriedRecord.pendingRevisions.contains { $0.content == "X local fork" })
        #expect(!retriedRecord.pendingRevisions.contains { $0.content == "R remote" })
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
        #expect(state.deviceSyncState == .writer)

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
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        #expect(await state.saveNow())
        await state.refreshSelectedEpisodeDeviceSync()

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
        #expect(state.deviceSyncState == .writer)

        await server.pauseNextPublish()
        state.updateEpisodeContent(
            "送信中の旧本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        await server.waitUntilPublishIsPaused()

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
        await server.waitUntilSnapshotResponseIsPaused()

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
        #expect(await server.currentHead(for: identity.syncKey)?.content == "R0")

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

    @Test("競合中のforce raceでも元localを保持した2-parent mergeだけを公開する")
    func conflictForceRacePreservesOriginalLocalParent() async throws {
        let episodeID = EpisodeID()
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let writerJournal = InMemoryEpisodeSyncJournal()
        let writer = EpisodeSyncCoordinator(
            key: key,
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
        try await appJournal.save(
            EpisodeSyncJournalRecord(
                key: key,
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
        let localWorkingCopyID = LocalWorkingCopyID()
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
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        let presentedConflict = try #require(state.deviceSyncConflict)
        #expect(presentedConflict.local == originalConflict.local)
        #expect(presentedConflict.remote == originalConflict.remote)
        #expect(state.document.episode(episodeID)?.episode.content == "X package-only draft")
        #expect(state.pendingDeviceSyncConflictResolution?.content == "X package-only draft")

        _ = try await writer.recordLocalContent("C raced remote", createdAt: now.addingTimeInterval(2))
        _ = try await writer.synchronize()
        let remoteC = try #require(await server.currentHead(for: key))
        #expect(remoteC.content == "C raced remote")

        await state.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: presentedConflict
        )

        let rebasedConflict = try #require(state.deviceSyncConflict)
        #expect(rebasedConflict.local.revisionID == localA.revisionID)
        #expect(rebasedConflict.remote.revisionID == remoteC.revisionID)
        #expect(state.pendingDeviceSyncConflictResolution?.content == localA.content)
        let loadedRebasedMarker = await mergeRecoveryStore.load(
            localWorkingCopyID: localWorkingCopyID,
            key: key
        )
        let rebasedMarker = try #require(loadedRebasedMarker)
        #expect(rebasedMarker.content == localA.content)
        #expect(rebasedMarker.parentRevisionIDs == Set([localA.revisionID, remoteC.revisionID]))
        await state.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: rebasedConflict
        )

        let mergedHead = try #require(await server.currentHead(for: key))
        #expect(mergedHead.content == localA.content)
        #expect(Set(mergedHead.parentRevisionIDs) == Set([localA.revisionID, remoteC.revisionID]))
        #expect(!mergedHead.parentRevisionIDs.contains(remoteB.revisionID))
        #expect(state.document.episode(episodeID)?.episode.content == localA.content)
        #expect(state.deviceSyncConflict == nil)
        #expect(state.deviceSyncState == .writer)
        let storedRecord = try #require(await appJournal.storedRecord(for: key))
        #expect(storedRecord.conflict == nil)
        #expect(storedRecord.localHead.revisionID == mergedHead.revisionID)
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
        journal: any EpisodeSyncJournal
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
            allowedEpisodeIDs: Set(document.chapters.flatMap(\.episodes).map(\.id))
        )
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

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-DeviceSync-App-Tests", isDirectory: true)
            .appendingPathComponent("\(name).novelpkg", isDirectory: true)
    }
}

private actor DeviceSyncAppRepository: DocumentRepository {
    private var documents: [String: NovelDocument] = [:]
    private var saveObserver: (@Sendable (NovelDocument) async -> Void)?

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
        documents[url.standardizedFileURL.path] = document
        if let saveObserver {
            await saveObserver(document)
        }
    }

    func setSaveObserver(_ observer: (@Sendable (NovelDocument) async -> Void)?) {
        saveObserver = observer
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

    func waitUntilFirstLookupIsPaused() async {
        while firstContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstLookup(with resolution: DeviceSyncBindingResolution?) {
        firstContinuation?.resume(returning: resolution)
        firstContinuation = nil
    }

    func observedLookupCount() -> Int {
        lookupCount
    }
}

private enum DeviceSyncAppRepositoryError: Error {
    case missingDocument
    case rejectedPrivateCopy
}
