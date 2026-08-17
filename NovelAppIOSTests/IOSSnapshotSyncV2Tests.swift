import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
struct IOSSnapshotSyncV2Tests {
    @Test("offline test runtime checkpoints SQLite without writing a novpkg")
    func checkpointIsLocalFirst() async throws {
        let runID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-v2-\(runID)", isDirectory: true)
        let defaults = try #require(
            UserDefaults(suiteName: "dev.serikayuzuki.fuminiwa.ios.v2.\(runID)")
        )
        defer {
            defaults.removePersistentDomain(
                forName: "dev.serikayuzuki.fuminiwa.ios.v2.\(runID)"
            )
            try? FileManager.default.removeItem(at: root)
        }

        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("SQLite正本")
        #expect(await store.saveNow())
        #expect(!FileManager.default.fileExists(atPath: store.documentURL.path))
        #expect(store.snapshotSyncOutcome == .pending || store.snapshotSyncOutcome == .offline)
    }
}
