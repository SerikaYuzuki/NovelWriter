import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSync
import NovelSyncTesting
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS Device Sync integration", .serialized)
struct IOSDeviceSyncIntegrationTests {
    @Test("forceは確認要求だけでは開始せず明示確認後に一度だけ開始する")
    func forceContinuationRequiresExplicitConfirmation() {
        var confirmation = IOSDeviceSyncForceContinuationConfirmation()
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

        let draft = IOSDeviceSyncConflictDraft(
            conflict: EpisodeConflict(base: base, local: local, remote: remote)
        )

        #expect(draft.kind == .automaticIntegration)
        #expect(draft.content == "吾輩は黒猫である。名前はまだ無い。")
        #expect(draft.title == "自動統合の下書き")
    }

    @Test("sync準備失敗はURL open・import・新規作成で迂回できない")
    func deviceSyncStartupFailureIsSticky() async throws {
        let fixture = try makeFixture(content: "protected")
        let app = makeStore(
            fixture: fixture,
            server: InMemoryEpisodeSyncServer(),
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "protected.novelpkg"
        )
        let originalDocument = app.store.document
        let originalURL = app.store.documentURL
        let originalGeneration = app.store.documentSessionGeneration

        app.store.failStartupForDeviceSyncSafety()
        #expect(!(await app.store.makeNewDocument()))
        #expect(!(await app.store.importPackage(from: originalURL)))
        #expect(!(await app.store.handleExternalPackageURL(originalURL)))
        #expect(!(await app.store.openPrivateDocument(id: IOSPrivateDocumentID(packageName: "protected.novelpkg"))))
        app.store.install(
            NovelDocument.newDocument(title: "must not install"),
            at: originalURL,
            attachments: []
        )

        guard case .recovery = app.store.startupState else {
            Issue.record("Device Syncの安全停止がRecoveryになっていません。")
            return
        }
        #expect(app.store.document == originalDocument)
        #expect(app.store.documentURL == originalURL)
        #expect(app.store.documentSessionGeneration == originalGeneration)
        #expect(app.store.deviceSyncStartupFailedSafely)
    }

    @Test("別端末で編集中は選択可能なread-onlyになり明示force後だけ入力可能になる")
    func realTextViewBecomesEditableOnlyAfterExplicitForce() async throws {
        let fixture = try makeFixture(content: "shared remote")
        let server = InMemoryEpisodeSyncServer()
        let writer = makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "writer.novelpkg"
        )
        let follower = makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "follower.novelpkg"
        )

        await prepareSelectedEpisode(in: writer.store)
        #expect(writer.store.deviceSyncState == .writer)
        await prepareSelectedEpisode(in: follower.store)
        #expect(follower.store.deviceSyncState == .readOnly)

        let rejectedIdentity = try #require(follower.store.activeDeviceSyncIdentity)
        let epochBeforeRejectedForce = await server.currentLeaseEpoch(for: fixture.key)
        follower.store.deviceSyncState = .writer
        await follower.store.forceContinueOnThisIPhone(expectedIdentity: rejectedIdentity)
        #expect(await server.currentLeaseEpoch(for: fixture.key) == epochBeforeRejectedForce)
        follower.store.deviceSyncState = .readOnly

        let harness = try await makeEditorHarness(store: follower.store)
        defer { harness.cleanup() }
        #expect(!harness.textView.isEditable)
        #expect(harness.textView.isSelectable)
        harness.textView.selectedRange = NSRange(location: 0, length: 6)
        #expect(harness.textView.selectedRange == NSRange(location: 0, length: 6))

        let expectedIdentity = try #require(follower.store.activeDeviceSyncIdentity)
        await follower.store.forceContinueOnThisIPhone(expectedIdentity: expectedIdentity)
        await advanceMainRunLoop(iterations: 4)
        let currentTextView = try #require(findTextView(in: harness.host.view))

        #expect(follower.store.deviceSyncState == .writer)
        #expect(currentTextView.isEditable)
        #expect(currentTextView.isSelectable)
    }

    @Test("normal release後はrefreshと再選択のどちらもforceなしで引き継げる")
    func normalReleaseSupportsRefreshAndRevisit() async throws {
        let fixture = try makeFixture(content: "shared")
        let server = InMemoryEpisodeSyncServer()
        let first = makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "normal-handoff-first.novelpkg"
        )
        let second = makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "normal-handoff-second.novelpkg"
        )

        await prepareSelectedEpisode(in: first.store)
        await prepareSelectedEpisode(in: second.store)
        #expect(first.store.deviceSyncState == .writer)
        #expect(second.store.deviceSyncState == .readOnly)

        let firstIdentity = try #require(first.store.activeDeviceSyncIdentity)
        let firstClient = try #require(first.store.deviceSyncClient(for: firstIdentity))
        _ = try await firstClient.coordinator.releaseEditingAuthority()

        await second.store.refreshSelectedEpisodeDeviceSync()
        #expect(second.store.deviceSyncState == .writer)

        let secondIdentity = try #require(second.store.activeDeviceSyncIdentity)
        let secondClient = try #require(second.store.deviceSyncClient(for: secondIdentity))
        _ = try await secondClient.coordinator.releaseEditingAuthority()

        first.store.deviceSyncSelectionDidChange()
        await prepareSelectedEpisode(in: first.store)
        #expect(first.store.deviceSyncState == .writer)
    }

    @Test("authority confirm再試行はinstall済みremoteでlocal forkを置換しない")
    func authorityConfirmRetryPreservesExistingLocalFork() async throws {
        let fixture = try makeFixture(content: "R remote")
        let server = InMemoryEpisodeSyncServer()
        let now = Date(timeIntervalSince1970: 15_000)
        let writer = EpisodeSyncCoordinator(
            key: fixture.key,
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

        let appJournal = InMemoryEpisodeSyncJournal()
        let app = makeStore(
            fixture: fixture,
            server: server,
            journal: appJournal,
            replicaID: SyncReplicaID(),
            packageName: "confirm-retry.novelpkg",
            now: { now.addingTimeInterval(10) }
        )
        await prepareSelectedEpisode(in: app.store)
        #expect(app.store.deviceSyncState == .readOnly)

        app.store.updateEpisodeContent(
            "X local fork",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID
        )
        let failureTrigger = IOSConfirmFailureSaveObserver(
            episodeID: fixture.episodeID,
            localContent: "X local fork",
            remoteContent: "R remote",
            server: server
        )
        await app.repository.setSaveObserver { document in
            await failureTrigger.observe(document)
        }

        let forceIdentity = try #require(app.store.activeDeviceSyncIdentity)
        await app.store.forceContinueOnThisIPhone(expectedIdentity: forceIdentity)
        #expect(await failureTrigger.didTriggerFailure())
        let failedRecord = try #require(await appJournal.storedRecord(for: fixture.key))
        #expect(failedRecord.pendingRevisions.contains { $0.content == "X local fork" })
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "R remote")

        await app.repository.setSaveObserver(nil)
        await server.setOnline(true)
        await prepareSelectedEpisode(in: app.store)

        let retriedRecord = try #require(await appJournal.storedRecord(for: fixture.key))
        #expect(retriedRecord.pendingRevisions.contains { $0.content == "X local fork" })
        #expect(!retriedRecord.pendingRevisions.contains { $0.content == "R remote" })
    }

    @Test("fenceは実UITextViewのIMEを確定しlocal fork保存後にremote本文をinstallする")
    func fenceCommitsMarkedTextBeforeRemoteInstall() async throws {
        let fixture = try makeFixture(content: "B remote")
        let server = InMemoryEpisodeSyncServer()
        let appJournal = InMemoryEpisodeSyncJournal()
        let app = makeStore(
            fixture: fixture,
            server: server,
            journal: appJournal,
            replicaID: SyncReplicaID(),
            packageName: "ime-writer.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        #expect(app.store.deviceSyncState == .writer)
        let oldEditingToken = try #require(app.store.currentEpisodeEditingToken)
        let oldGeneration = app.store.editorContentGeneration

        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }
        beginMarkedText("変換中", in: harness.textView)
        #expect(harness.textView.markedTextRange != nil)

        let other = EpisodeSyncCoordinator(
            key: fixture.key,
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        let now = Date(timeIntervalSince1970: 20_000)
        _ = try await other.link(
            localContent: fixture.content,
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        _ = try await other.claimEditingAuthority(expiresAt: now.addingTimeInterval(600))
        let grant = try await other.prepareForcedContinuation(expiresAt: now.addingTimeInterval(600))
        _ = try await other.confirmAuthorityInstall(
            grant,
            installedRemoteDigest: grant.snapshot.head?.contentDigest
        )
        _ = try await other.recordLocalContent("C new remote", createdAt: now.addingTimeInterval(1))
        _ = try await other.synchronize()

        await app.store.refreshSelectedEpisodeDeviceSync()
        await advanceMainRunLoop(iterations: 4)

        let record = try #require(await appJournal.storedRecord(for: fixture.key))
        let conflict = try #require(record.conflict)
        #expect(conflict.local.content.contains("変換中"))
        #expect(conflict.remote.content == "C new remote")
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "C new remote")
        #expect(app.store.editorContentGeneration > oldGeneration)
        #expect(app.store.deviceSyncConflict?.local.content.contains("変換中") == true)
        guard case let .conflict(presentedConflict) = app.store.deviceSyncState else {
            Issue.record("fence後に競合状態が表示されていません。")
            return
        }
        #expect(presentedConflict == app.store.deviceSyncConflict)
        #expect(harness.textView.markedTextRange == nil)

        app.store.updateEpisodeContent(
            "stale surface callback",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: oldEditingToken
        )
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "C new remote")

        let currentTextView = try #require(findTextView(in: harness.host.view))
        #expect(currentTextView.text == "C new remote")
        #expect(!currentTextView.isEditable)
        #expect(currentTextView.isSelectable)
    }

    @Test("旧sealed再送後に残る最新tailも入力停止中に送信する")
    func publishRetriesTailAfterInterruptedSealedBatch() async throws {
        let fixture = try makeFixture(content: "initial")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let app = makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "publish-tail.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        #expect(app.store.deviceSyncState == .writer)

        await server.cancelNextPublish()
        let firstToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "first sealed",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: firstToken
        )
        await app.store.deviceSyncDraftTask?.value
        let interrupted = try #require(await journal.storedRecord(for: fixture.key))
        #expect(interrupted.sealedPublish != nil)

        let latestToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "latest tail",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: latestToken
        )
        await app.store.deviceSyncDraftTask?.value

        let remote = try #require(await server.currentHead(for: fixture.key))
        let settled = try #require(await journal.storedRecord(for: fixture.key))
        #expect(remote.content == "latest tail")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(settled.sealedPublish == nil)
        #expect(app.store.deviceSyncTransferState == .upToDate)
    }

    @Test("競合force raceは元localをremote editor本文で置換せず2-parent mergeする")
    func conflictForceRacePreservesOriginalLocalParent() async throws {
        let fixture = try makeFixture(content: "B remote")
        let server = InMemoryEpisodeSyncServer()
        let writer = EpisodeSyncCoordinator(
            key: fixture.key,
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        let now = Date(timeIntervalSince1970: 30_000)
        _ = try await writer.link(
            localContent: fixture.content,
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        let remoteB = try #require(await server.currentHead(for: fixture.key))

        let appJournal = InMemoryEpisodeSyncJournal()
        let mergeRecoveryStore = IOSInMemoryDeviceSyncMergeRecoveryStore()
        let localA = try EpisodeRevision(
            key: fixture.key,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: "A local fork",
            clientCreatedAt: now.addingTimeInterval(1)
        )
        try await appJournal.save(
            EpisodeSyncJournalRecord(
                key: fixture.key,
                branchID: localA.branchID,
                lastKnownRemoteHead: remoteB,
                localHead: localA,
                pendingRevisions: [localA],
                conflict: EpisodeConflict(base: nil, local: localA, remote: remoteB),
                mode: .forcedFork
            )
        )
        let app = makeStore(
            fixture: fixture,
            server: server,
            journal: appJournal,
            replicaID: SyncReplicaID(),
            packageName: "conflict-race.novelpkg",
            mergeRecoveryStore: mergeRecoveryStore,
            now: { now.addingTimeInterval(10) }
        )
        app.store.document.updateEpisodeContent(
            "X package-only draft",
            for: fixture.episodeID,
            in: fixture.chapterID
        )
        await prepareSelectedEpisode(in: app.store)
        let presentedConflict = try #require(app.store.deviceSyncConflict)
        #expect(presentedConflict.local.revisionID == localA.revisionID)
        #expect(presentedConflict.remote.revisionID == remoteB.revisionID)
        #expect(app.store.pendingDeviceSyncConflictResolution?.content == "X package-only draft")

        _ = try await writer.recordLocalContent("C raced remote", createdAt: now.addingTimeInterval(2))
        _ = try await writer.synchronize()
        let remoteC = try #require(await server.currentHead(for: fixture.key))

        await app.store.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: presentedConflict
        )

        let rebasedConflict = try #require(app.store.deviceSyncConflict)
        #expect(rebasedConflict.local.revisionID == localA.revisionID)
        #expect(rebasedConflict.remote.revisionID == remoteC.revisionID)
        #expect(app.store.pendingDeviceSyncConflictResolution?.content == localA.content)
        let rebasedLocalWorkingCopyID = try #require(
            app.store.activeDeviceSyncIdentity?.localWorkingCopyID
        )
        let loadedRebasedMarker = await mergeRecoveryStore.load(
            localWorkingCopyID: rebasedLocalWorkingCopyID,
            key: fixture.key
        )
        let rebasedMarker = try #require(loadedRebasedMarker)
        #expect(rebasedMarker.content == localA.content)
        #expect(rebasedMarker.parentRevisionIDs == Set([localA.revisionID, remoteC.revisionID]))
        await app.store.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: rebasedConflict
        )

        let mergedHead = try #require(await server.currentHead(for: fixture.key))
        #expect(mergedHead.content == localA.content)
        #expect(Set(mergedHead.parentRevisionIDs) == Set([localA.revisionID, remoteC.revisionID]))
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == localA.content)
        #expect(app.store.deviceSyncConflict == nil)
        #expect(app.store.deviceSyncState == .writer)
    }

    private func prepareSelectedEpisode(in store: IOSDocumentStore) async {
        guard let lookup = store.currentDeviceSyncLookupIdentity else {
            Issue.record("選択中の話にDevice Sync identityがありません。")
            return
        }
        await store.prepareDeviceSync(for: lookup)
    }

    private func makeStore(
        fixture: IOSDeviceSyncFixture,
        server: InMemoryEpisodeSyncServer,
        journal: InMemoryEpisodeSyncJournal,
        replicaID: SyncReplicaID,
        packageName: String,
        mergeRecoveryStore: any IOSDeviceSyncMergeRecoveryStoring = IOSInMemoryDeviceSyncMergeRecoveryStore(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 10_000) }
    ) -> (store: IOSDocumentStore, repository: IOSDeviceSyncRepository) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-DeviceSync-Tests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(packageName, isDirectory: true)
        let repository = IOSDeviceSyncRepository()
        let localWorkingCopyID = LocalWorkingCopyID()
        let resolution = IOSDeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: fixture.key.workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: fixture.key.workID,
                sourceDocumentID: fixture.document.id,
                structureDigest: fixture.structureDigest,
                title: fixture.document.title
            ),
            journal: journal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id))
        )
        let runtime = IOSDeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _, _ in
                resolution
            },
            mergeRecoveryStore: mergeRecoveryStore,
            now: now,
            leaseDuration: 600
        )
        let suiteName = "FUMINIWAIOS.DeviceSyncIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = IOSDocumentStore(
            repository: repository,
            userDefaults: defaults,
            deviceSyncRuntime: runtime,
            libraryRoot: root
        )
        store.install(fixture.document, at: url, attachments: [])
        store.startupState = .ready
        store.saveState = .saved
        return (store, repository)
    }

    private func makeFixture(content: String) throws -> IOSDeviceSyncFixture {
        let chapterID = ChapterID()
        let episodeID = EpisodeID()
        let document = NovelDocument(
            title: "sync fixture",
            chapters: [
                Chapter(
                    id: chapterID,
                    title: "chapter",
                    episodes: [Episode(id: episodeID, content: content)]
                )
            ]
        )
        return IOSDeviceSyncFixture(
            document: document,
            chapterID: chapterID,
            episodeID: episodeID,
            key: EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID),
            structureDigest: try SyncWorkStructureDigest(chapters: document.chapters),
            content: content
        )
    }

    private func makeEditorHarness(store: IOSDocumentStore) async throws -> IOSDeviceSyncEditorHarness {
        let host = UIHostingController(rootView: IOSEditorPane(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()

        for _ in 0 ..< 16 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if let textView = findTextView(in: host.view) {
                _ = textView.becomeFirstResponder()
                return IOSDeviceSyncEditorHarness(window: window, host: host, textView: textView)
            }
            await advanceMainRunLoop()
        }
        window.isHidden = true
        window.rootViewController = nil
        throw IOSDeviceSyncTestError.textViewNotFound
    }

    private func beginMarkedText(_ text: String, in textView: UITextView) {
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
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

    private func advanceMainRunLoop(iterations: Int = 1) async {
        for _ in 0 ..< iterations {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform {
                    continuation.resume()
                }
            }
        }
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}

private struct IOSDeviceSyncFixture {
    let document: NovelDocument
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let key: EpisodeSyncKey
    let structureDigest: SyncWorkStructureDigest
    let content: String
}

@MainActor
private struct IOSDeviceSyncEditorHarness {
    let window: UIWindow
    let host: UIHostingController<IOSEditorPane>
    let textView: UITextView

    func cleanup() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private actor IOSDeviceSyncRepository: DocumentCopyingRepository {
    private var documents: [String: NovelDocument] = [:]
    private var saveObserver: (@Sendable (NovelDocument) async -> Void)?

    func load(from url: URL) async throws -> NovelDocument {
        guard let document = documents[url.standardizedFileURL.path] else {
            throw IOSDeviceSyncTestError.missingDocument
        }
        return document
    }

    func save(_ document: NovelDocument, to url: URL) async throws {
        documents[url.standardizedFileURL.path] = document
        if let saveObserver {
            await saveObserver(document)
        }
    }

    func saveCopy(_ document: NovelDocument, from _: URL, to destinationURL: URL) async throws {
        documents[destinationURL.standardizedFileURL.path] = document
    }

    func setSaveObserver(_ observer: (@Sendable (NovelDocument) async -> Void)?) {
        saveObserver = observer
    }
}

private actor IOSConfirmFailureSaveObserver {
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

private enum IOSDeviceSyncTestError: Error {
    case missingDocument
    case textViewNotFound
}
