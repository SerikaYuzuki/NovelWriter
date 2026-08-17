import Foundation
@testable import FUMINIWAIOS
import NovelCore
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

        let oldDocument = store.document
        let oldCreatedAt = store.documentCreatedAt
        let oldURL = store.documentURL
        let oldChapterID = store.selectedChapterID
        let oldEpisodeID = store.selectedEpisodeID
        let oldSession = store.currentDocumentSessionToken
        let oldWorkID = store.syncV2ActiveWorkID
        let oldRecentWorkID = environment.defaults.string(forKey: IOSDocumentStore.lastWorkIDKey)

        // Preview deterministically rejects checkpoint writes at the
        // application boundary without touching the test SQLite store.
        store.snapshotSyncV2Application = try await SnapshotSyncV2Runtime.makeApplication(
            mode: .preview(PreviewRuntimeConfiguration())
        )
        #expect(await !store.makeNewDocument())

        #expect(store.document == oldDocument)
        #expect(store.documentCreatedAt == oldCreatedAt)
        #expect(store.documentURL == oldURL)
        #expect(store.selectedChapterID == oldChapterID)
        #expect(store.selectedEpisodeID == oldEpisodeID)
        #expect(store.currentDocumentSessionToken == oldSession)
        #expect(store.syncV2ActiveWorkID == oldWorkID)
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

        let state = store.snapshotSyncState
        #expect(state?.workID == store.syncV2ActiveWorkID)
        #expect(state?.localDurability != .saving)
        #expect(state?.japaneseLabel == state?.remoteProgress.japaneseLabel)
        #expect(
            state?.japaneseLabel == "同期待ち"
                || state?.japaneseLabel == "端末に保存済み・通信待ち"
        )
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-v2-p1-(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.v2.p1.(id)"
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
