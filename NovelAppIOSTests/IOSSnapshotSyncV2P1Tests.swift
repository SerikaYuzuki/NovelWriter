import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct IOSSnapshotSyncV2P1Tests {
    @Test("新規作品のcheckpoint失敗では現在の作品を完全に維持する")
    func newDocumentCheckpointFailureKeepsCurrentWork() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("Work A")
        #expect(await store.saveNow())

        let oldDocument = store.workspaceModel.document
        let oldCreatedAt = store.documentCreatedAt
        let oldURL = store.documentURL
        let oldChapterID = store.workspaceModel.selectedChapterID
        let oldEpisodeID = store.workspaceModel.selectedEpisodeID
        let oldSession = store.currentDocumentSessionToken
        let oldWorkID = store.workspaceModel.activeWorkID
        let oldRecentWorkID = environment.defaults.string(forKey: IOSDocumentStore.lastWorkIDKey)

        // Preview deterministically rejects checkpoint writes at the
        // application boundary without touching the test SQLite store.
        store.snapshotSyncV2Application = try await SnapshotSyncV2Runtime.makeApplication(
            mode: .preview(PreviewRuntimeConfiguration())
        )
        #expect(await !store.makeNewDocument())

        #expect(store.workspaceModel.document == oldDocument)
        #expect(store.documentCreatedAt == oldCreatedAt)
        #expect(store.documentURL == oldURL)
        #expect(store.workspaceModel.selectedChapterID == oldChapterID)
        #expect(store.workspaceModel.selectedEpisodeID == oldEpisodeID)
        #expect(store.currentDocumentSessionToken == oldSession)
        #expect(store.workspaceModel.activeWorkID == oldWorkID)
        #expect(environment.defaults.string(forKey: IOSDocumentStore.lastWorkIDKey) == oldRecentWorkID)
    }

    @Test("checkpoint結果はworkerのpending状態を即時共有projectionへ反映する")
    func checkpointProjectsPendingStateImmediately() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("共有projection")
        #expect(await store.saveNow())

        let state = store.workspaceModel.syncUIState
        #expect(state?.workID == store.workspaceModel.activeWorkID)
        guard case .saved = state?.localDurability else {
            Issue.record("checkpoint did not project a durable local save")
            return
        }
        #expect(state?.japaneseLabel == state?.remoteProgress.japaneseLabel)
        // The worker may already be sending when saveNow returns. All three
        // states mean the local checkpoint is safe but remote delivery is pending.
        switch state?.remoteProgress {
        case .pending, .syncing, .offline: break
        default: Issue.record("unexpected post-checkpoint state: \(String(describing: state?.remoteProgress))")
        }
    }

    @Test("未保存の本文をgate内で保存して履歴に残してから作品全体を復元する")
    func wholeWorkRestorePreservesUnsavedTextInHistory() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(userDefaults: environment.defaults, libraryRoot: environment.root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let app = try #require(store.snapshotSyncV2Application)
        let workID = try #require(store.workspaceModel.activeWorkID)
        let snapshot = try #require(try await app.currentSnapshotID(workID: workID))
        let original = store.workspaceModel.document
        store.updateEpisodeContent("復元直前の未保存本文", chapterID: original.chapters[0].id,
                                   episodeID: original.chapters[0].episodes[0].id)
        let unsaved = store.workspaceModel.document
        #expect(store.workspaceModel.saveState == .unsaved)
        #expect(await store.restoreSnapshotSyncV2(snapshotID: snapshot.rawValue))
        #expect(store.workspaceModel.document == original)
        #expect(store.workspaceModel.saveState == .saved)
        let page = try await app.historyPage(workID: workID, cursor: nil, pageSize: 100)
        var preserved = false
        for entry in page.items where entry.source == .local {
            let body = try await app.snapshotEpisodePreview(workID: workID, snapshotID: entry.snapshotID,
                                                            episodeID: original.chapters[0].episodes[0].id.rawValue.uuidString.lowercased())
            if body == unsaved.chapters[0].episodes[0].content {
                preserved = true
            }
        }
        #expect(preserved)
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-v2-p1-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.v2.p1.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
private struct TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        let key = root.standardizedFileURL
        IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: key)
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
