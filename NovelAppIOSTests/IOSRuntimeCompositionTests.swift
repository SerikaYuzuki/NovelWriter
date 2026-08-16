import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
struct IOSRuntimeCompositionTests {
    @Test("iOS app test composition never creates HTTP transports")
    func appCompositionIsOffline() throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-runtime-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.runtime.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set("http://192.168.11.5:18080", forKey: "fuminiwa.syncServerURL")

        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)

        #expect(store.authSessionCoordinator == nil)
        #expect(store.localSnapshotSyncWorker == nil)
        #expect(store.authUIState == .unavailable)
    }
}
