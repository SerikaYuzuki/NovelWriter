import Foundation
@testable import FUMINIWAIOS
import NovelSyncV2Application
import Testing

#if !FUMINIWA_TEST_COMPOSITION
#error("FUMINIWAIOSTests must be hosted by the compile-time isolated test application")
#endif

@MainActor
struct IOSRuntimeCompositionTests {
    @Test("iOS app-host save keeps production persistence untouched")
    func appCompositionIsPhysicallyIsolated() async throws {
        let configuration = try TestRuntimeConfiguration()
        let root = configuration.localRoot.url
        let suiteName = configuration.defaults.suiteName
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("http://192.168.11.5:18080", forKey: "fuminiwa.syncServerURL")

        let productionStoreURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("SnapshotSyncV2", isDirectory: true)
            .appendingPathComponent("snapshot-sync-v2.sqlite")
        let productionStoreBefore = sqliteInventory(at: productionStoreURL)
        let productionEndpointBefore = UserDefaults.standard.string(forKey: "fuminiwa.syncServerURL")

        let store = IOSDocumentStore(
            userDefaults: defaults,
            libraryRoot: root,
            runtimeComposition: .test(configuration)
        )

        #expect(store.libraryRoot == root.standardizedFileURL)
        #expect(store.userDefaults === defaults)
        #expect(store.authSessionCoordinator == nil)
        #expect(store.appleSignInCoordinator == nil)
        #expect(store.appleAuthenticationOrchestrator == nil)
        #expect(store.authUIState == .unavailable)
        #expect(await configuration.vault.currentAccount()?.accountID == "test-account")
        #expect(await configuration.vault.currentAccount()?.accountFence == "test-fence")
        #expect(await store.configureSnapshotSyncV2())
        #expect(store.snapshotSyncV2Application != nil)
        await store.bootstrap()
        #expect(await store.makeNewDocument())

        let application = try #require(store.snapshotSyncV2Application)
        let workID = try #require(store.syncV2ActiveWorkID)
        var observedRemoteProgress: SyncV2RemoteProgress?
        for _ in 0 ..< 100 {
            observedRemoteProgress = await application.uiState(workID: workID)?.remoteProgress
            if observedRemoteProgress == .offline {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedRemoteProgress == .offline)
        let fakeCallsBeforeNoOpSave = await configuration.remote.recordedOperations().count

        #expect(await store.saveNow())
        await Task.yield()

        #expect(await configuration.remote.recordedOperations().count == fakeCallsBeforeNoOpSave)
        #expect(sqliteInventory(at: productionStoreURL) == productionStoreBefore)
        #expect(UserDefaults.standard.string(forKey: "fuminiwa.syncServerURL") == productionEndpointBefore)
    }

    private func sqliteInventory(at url: URL) -> IOSSQLiteInventory {
        let fileManager = FileManager.default
        let paths = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ]
        let files = Dictionary(uniqueKeysWithValues: paths.map { path in
            let attributes = try? fileManager.attributesOfItem(atPath: path.path)
            return (
                path.lastPathComponent,
                IOSSQLiteFileSignature(
                    exists: attributes != nil,
                    size: attributes?[.size] as? UInt64,
                    modificationDate: attributes?[.modificationDate] as? Date
                )
            )
        })
        return IOSSQLiteInventory(files: files)
    }
}

private struct IOSSQLiteInventory: Equatable {
    let files: [String: IOSSQLiteFileSignature]
}

private struct IOSSQLiteFileSignature: Equatable {
    let exists: Bool
    let size: UInt64?
    let modificationDate: Date?
}
