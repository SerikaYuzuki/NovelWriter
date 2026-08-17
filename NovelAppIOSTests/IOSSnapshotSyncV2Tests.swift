import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import Testing

@MainActor
struct IOSSnapshotSyncV2Tests {
    @Test("offline test runtime checkpoints SQLite without writing a novpkg")
    func checkpointIsLocalFirst() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }

        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("SQLite正本")
        #expect(await store.saveNow())
        #expect(store.documentURL == environment.root.standardizedFileURL)
        #expect(!FileManager.default.fileExists(
            atPath: environment.root.appendingPathComponent(store.document.id.uuidString).path
        ))
        #expect(store.snapshotSyncOutcome == .pending || store.snapshotSyncOutcome == .offline)
    }

    @Test("normal new/open never creates a WorkID directory")
    func workIDIsNotAFileSystemArtifact() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID).rawValue
        #expect(await store.openSnapshotSyncV2(workID: workID))
        #expect(store.documentURL == environment.root.standardizedFileURL)
        #expect(!FileManager.default.fileExists(
            atPath: environment.root.appendingPathComponent(workID.uuidString).path
        ))
    }

    @Test("WorkIDはDocumentIDから独立したsession identityになる")
    func workIdentityIsNotDocumentIdentity() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        #expect(workID.rawValue != store.document.id)
        #expect(store.currentDocumentSessionToken?.workID == workID)
    }

    @Test("3択は実際のSyncV2ConflictActionへ写像できる")
    func conflictChoicesAreTypedActions() {
        let workID = WorkID(UUID())
        let local = SnapshotID(data: Data("local".utf8))
        let remote = SnapshotID(data: Data("remote".utf8))
        let choices: [SyncV2ConflictChoice] = [.useDevice, .useServer, .keepBoth]
        #expect(Set(choices).count == 3)
        for choice in choices {
            let action = SyncV2ConflictAction(
                workID: workID,
                conflictID: UUID(),
                revision: 1,
                baseSnapshotID: nil,
                localSnapshotID: local,
                remoteSnapshotID: remote,
                sourceGeneration: 1,
                choice: choice
            )
            #expect(action.choice == choice)
            #expect(action.workID == workID)
        }
    }

    @Test("競合解決のno-opは冪等成功として再投影し、staleだけを再選択に戻す")
    func conflictResolutionResultIdempotency() {
        #expect(acceptsSnapshotSyncV2ConflictResult(.queued))
        #expect(acceptsSnapshotSyncV2ConflictResult(.noChanges))
        #expect(!acceptsSnapshotSyncV2ConflictResult(.staleConflictAction))
    }

    @Test("resumeはoffline workerを待たずにUIへ戻る")
    func resumeIsNonBlocking() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        await store.resumeSnapshotSyncV2()
        #expect(store.startupState == .ready)
        #expect(store.isDocumentTransitionInProgress == false)
    }

    @Test("remote-only open failure does not create a local WorkID artifact")
    func remoteOnlyOpenStaysInInboxBoundary() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        let workID = UUID()
        #expect(await store.openRemoteOnly(workID: WorkID(workID)) == false)
        #expect(!FileManager.default.fileExists(
            atPath: environment.root.appendingPathComponent(workID.uuidString).path
        ))
    }

    @Test("account-scoped catalog rows project remote-only work into the v2 shelf")
    func remoteCatalogProjectsRemoteOnlyWork() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        let workID = WorkID(UUID())
        let rows = store.mergeRemoteCatalog(
            into: [],
            catalog: [SyncV2RemoteCatalogEntry(workID: workID, title: "サーバー作品", head: nil)]
        )
        #expect(rows.count == 1)
        #expect(rows.first?.workID == workID)
        #expect(rows.first?.availability == .remoteOnly)
        #expect(rows.first?.accountState == .active)
    }

    @Test("missing v2 attachment bytes fail closed without dropping metadata")
    func missingAttachmentBytesDoNotCheckpointPartially() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.replaceAttachments([Attachment(fileName: "missing.pdf", byteCount: 12)])
        #expect(await store.checkpointSnapshotSyncV2(store.document, reason: .explicit) == false)
        #expect(store.attachments.map(\.fileName) == ["missing.pdf"])
        #expect(store.snapshotSyncOutcome == .failed)
    }

    @Test("履歴UIはSQLite localとremoteを同一projectionへ載せる")
    func historyProjectionRetainsLocalAvailabilityOffline() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("履歴の版")
        #expect(await store.saveNow())
        let workID = try #require(store.syncV2ActiveWorkID)

        #expect(await store.refreshSnapshotHistory(for: workID))
        #expect(!store.syncV2HistoryItems.isEmpty)
        #expect(store.syncV2HistoryLocalAvailability == .available)
        #expect(store.syncV2HistoryItems.contains { $0.source == .local })
    }

    @Test("restoreはSQLiteのlocal resultを再openしてeditor modelへ反映する")
    func restoreReprojectsEditor() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        guard let app = store.snapshotSyncV2Application else {
            Issue.record("v2 application was not composed")
            return
        }
        store.updateDocumentTitle("復元前の版")
        #expect(await store.saveNow())
        let workID = try #require(store.syncV2ActiveWorkID)
        let first = try await app.checkpoint(
            workID: workID,
            document: store.document,
            reason: .explicit,
            documentCreatedAt: store.documentCreatedAt
        )
        store.updateDocumentTitle("現在の版")
        #expect(await store.saveNow())
        guard case let .saved(_, selectedSnapshotID) = first.state.localDurability else {
            Issue.record("checkpoint did not produce a durable snapshot")
            return
        }

        #expect(await store.restoreSnapshotSyncV2(snapshotID: selectedSnapshotID.rawValue))
        #expect(store.document.title == "復元前の版")
    }

    @Test("sign-outは旧accountのremote shelf/conflict/historyをparkする")
    func signOutIsolatesAccountProjection() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        let workID = WorkID(UUID())
        let snapshot = SnapshotID(data: Data("snapshot".utf8))
        store.syncV2LibraryItems = [SyncV2LibraryItem(
            workID: workID,
            title: "旧アカウント",
            availability: .cached,
            accountState: .active
        )]
        store.syncV2RemoteCatalogItems = [
            SyncV2RemoteCatalogEntry(workID: workID, title: "旧アカウント", head: nil)
        ]
        store.snapshotSyncConflict = SyncV2ConflictProjection(
            conflictID: UUID(), revision: 1, baseSnapshotID: nil,
            localSnapshotID: snapshot, remoteSnapshotID: snapshot,
            sourceGeneration: 1
        )
        await store.signOutFromFuminiwa()
        #expect(store.syncV2LibraryItems.isEmpty)
        #expect(store.syncV2RemoteCatalogItems.isEmpty)
        #expect(store.snapshotSyncConflict == nil)
        #expect(store.snapshotSyncState == nil)
    }

    @Test("unbound workはsign-out後も残り、sign-in後の明示clone対象になる")
    func signOutPreservesUnboundWorkForExplicitClone() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        store.syncV2LibraryItems = [SyncV2LibraryItem(
            workID: workID,
            title: "端末作品",
            availability: .localOnly,
            accountState: .unbound
        )]

        await store.signOutFromFuminiwa()

        #expect(store.syncV2ActiveWorkID == workID)
        #expect(store.syncV2LibraryItems.map(\.workID) == [workID])
    }

    @Test("世代が進んだeditor callbackは現在の本文へ混入しない")
    func editRaceDoesNotCrossGeneration() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapterID = try #require(store.selectedChapterID)
        let episodeID = try #require(store.selectedEpisodeID)
        let staleToken = try #require(store.currentEpisodeEditingToken)
        store.document.updateEpisodeContent("新しい本文", for: episodeID, in: chapterID)
        store.advanceEditorContentGeneration()
        store.updateEpisodeContent(
            "遅れて届いた古い本文",
            chapterID: chapterID,
            episodeID: episodeID,
            expectedEditingToken: staleToken
        )
        #expect(store.document.episode(episodeID)?.episode.content == "新しい本文")
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-v2-focused-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.v2.focused.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

private struct TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
