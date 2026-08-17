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
    func workIDIsNotAFileSystemArtifact() async throws {
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

    @Test("公開open境界はdirty本文を先にSQLiteへcheckpointし、clean再openはno-opにする")
    func openCheckpointsDirtyCurrentWorkBeforeTarget() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let originalWorkID = try #require(store.syncV2ActiveWorkID)
        store.updateDocumentTitle("dirty本文")
        #expect(store.saveState == .dirty)

        let application = try #require(store.snapshotSyncV2Application)
        let runtimeConfiguration = try #require(
            IOSDocumentStore.testRuntimeConfigurations[environment.root.standardizedFileURL]
        )
        let targetWorkID = WorkID(UUID())
        let targetDocument = NovelDocument.newDocument(title: "別作品")
        _ = try await application.checkpoint(
            workID: targetWorkID,
            document: targetDocument,
            reason: .explicit,
            documentCreatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        try await waitForOfflineWorker(
            application,
            remote: runtimeConfiguration.remote,
            workID: targetWorkID
        )

        #expect(await store.openSnapshotSyncV2(workID: targetWorkID.rawValue))
        #expect(store.syncV2ActiveWorkID == targetWorkID)
        #expect(store.document.title == "別作品")
        #expect(await store.openSnapshotSyncV2(workID: originalWorkID.rawValue))
        #expect(store.document.title == "dirty本文")
        try await waitForOfflineWorker(
            application,
            remote: runtimeConfiguration.remote,
            workID: originalWorkID
        )

        let stateBeforeCleanReopen = try #require(await application.uiState(workID: originalWorkID))
        let remoteOperationsBeforeCleanReopen = await runtimeConfiguration.remote.recordedOperations()
        #expect(await store.openSnapshotSyncV2(workID: originalWorkID.rawValue))
        let stateAfterCleanReopen = try #require(await application.uiState(workID: originalWorkID))
        #expect(stateAfterCleanReopen.localDurability == stateBeforeCleanReopen.localDurability)
        let remoteOperationsAfterCleanReopen = await runtimeConfiguration.remote.recordedOperations()
        #expect(remoteOperationsAfterCleanReopen.count == remoteOperationsBeforeCleanReopen.count)
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

    private func waitForOfflineWorker(
        _ application: SyncV2Application,
        remote: FakeSyncV2RemoteClient,
        workID: WorkID
    ) async throws {
        var previousOperationCount: Int?
        var stableSamples = 0
        for _ in 0 ..< 100 {
            let operationCount = await remote.recordedOperations().count
            if let state = await application.uiState(workID: workID),
               case .offline = state.remoteProgress {
                if previousOperationCount == operationCount {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                }
                if stableSamples >= 3 {
                    return
                }
            } else {
                stableSamples = 0
            }
            previousOperationCount = operationCount
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("test worker did not reach the offline terminal state")
    }
}

@MainActor
extension IOSSnapshotSyncV2Tests {
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
        #expect(store.syncV2LibraryItems.map(\.workID) == [workID])
        #expect(store.syncV2LibraryItems.first?.availability == .localOnly)
        #expect(store.syncV2LibraryItems.first?.accountState == .parkedDifferentAccount)
        #expect(store.syncV2RemoteCatalogItems.isEmpty)
        #expect(store.snapshotSyncConflict == nil)
        #expect(store.snapshotSyncState == nil)
    }

    @Test("parked作品はlocal履歴をページングし、通信なしで復元できる")
    func parkedWorkRetainsLocalHistoryAndRestore() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let application = try #require(store.snapshotSyncV2Application)
        let workID = try #require(store.syncV2ActiveWorkID)
        var value = store.document
        var firstSnapshotID: SnapshotID?
        let createdAt = store.documentCreatedAt

        // More than the iOS page size creates a real local cursor. Direct
        // application checkpoints keep this fixture focused on SQLite and do
        // not make the UI's debounce timing part of the history contract.
        for index in 0 ..< 105 {
            value.title = "parked-\(index)"
            let result = try await application.checkpoint(
                workID: workID,
                document: value,
                reason: .explicit,
                documentCreatedAt: createdAt
            )
            if index == 0,
               case let .saved(_, snapshotID) = result.state.localDurability {
                firstSnapshotID = snapshotID
            }
        }
        store.document = value
        store.saveState = .saved
        #expect(firstSnapshotID != nil)
        // The isolated test composition has no AuthSessionCoordinator, so
        // its signed-out UI projection intentionally hides active rows. Seed
        // the pre-sign-out account row explicitly; the durable runtime still
        // owns the SQLite binding and performs the actual park transaction.
        store.syncV2LibraryItems = [SyncV2LibraryItem(
            workID: workID,
            title: value.title,
            availability: .cached,
            accountState: .active
        )]

        await store.signOutFromFuminiwa()
        #expect(store.isCurrentWorkParked)
        #expect(store.canRefreshSnapshotHistory)
        #expect(store.canRestoreLocalSnapshot)

        let runtimeConfiguration = try #require(
            IOSDocumentStore.testRuntimeConfigurations[environment.root.standardizedFileURL]
        )
        let remoteOperationsBeforeHistory = await runtimeConfiguration.remote.recordedOperations().count
        #expect(await store.refreshSnapshotHistory(for: workID))
        let firstPageCount = store.syncV2HistoryItems.count
        #expect(firstPageCount > 0)
        #expect(store.syncV2HistoryLocalAvailability == .available)
        #expect(store.syncV2HistoryOnlineAvailability == .unavailable)
        #expect(store.syncV2HistoryCursor != nil)
        #expect(
            await runtimeConfiguration.remote.recordedOperations().count
                == remoteOperationsBeforeHistory
        )

        #expect(await store.refreshSnapshotHistory(for: workID, reset: false))
        #expect(store.syncV2HistoryItems.count > firstPageCount)
        #expect(store.syncV2HistoryCursor == nil)
        #expect(
            await runtimeConfiguration.remote.recordedOperations().count
                == remoteOperationsBeforeHistory
        )

        let selectedSnapshotID = try #require(firstSnapshotID)
        #expect(await store.restoreSnapshotSyncV2(snapshotID: selectedSnapshotID.rawValue))
        #expect(store.document.title == "parked-0")
    }
}

@MainActor
private struct TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        let key = root.standardizedFileURL
        // The store can still retain the actor/database when defer runs.
        // Never unlink an open SQLite root; this is a UUID-scoped temporary
        // fixture and the OS cleans it up after the test process exits.
        IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: key)
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
