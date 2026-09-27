import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

#if !FUMINIWA_TEST_COMPOSITION
#error("NovelAppTests must be hosted by the compile-time isolated test application")
#endif

@MainActor
struct RuntimeCompositionTests {
    @Test("macOS test compositionはproduction URLやHTTP transportを作らない")
    func appCompositionUsesIsolatedTestRuntime() async throws {
        let configuration = try TestRuntimeConfiguration()
        let suiteName = configuration.defaults.suiteName
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("http://192.168.11.5:18080", forKey: "fuminiwa.syncServerURL")

        let dependencies = FuminiwaApp.makeTestDependencies(
            userDefaults: defaults,
            configuration: configuration
        )
        #expect(configuration.localRoot.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(dependencies.userDefaults === defaults)
        #expect(dependencies.defaultDocumentDirectoryName == "FUMINIWA-TestHost")
        #expect(dependencies.authSessionCoordinator == nil)
        #expect(dependencies.snapshotSyncV2Factory != nil)
        #expect(await configuration.vault.currentAccount()?.accountID == "test-account")
        #expect(await configuration.vault.currentAccount()?.accountFence == "test-fence")
        #expect(await configuration.remote.recordedOperations().isEmpty)
    }

    @Test("AppState test saveはproduction SQLite rootを変更しない")
    func appStateSaveDoesNotTouchProductionStore() async throws {
        let configuration = try TestRuntimeConfiguration()
        let suiteName = configuration.defaults.suiteName
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let productionStoreURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("SnapshotSyncV2", isDirectory: true)
            .appendingPathComponent("snapshot-sync-v2.sqlite")
        let before = try sqliteInventory(at: productionStoreURL)
        let productionEndpointBefore = UserDefaults.standard.string(
            forKey: "fuminiwa.syncServerURL"
        )
        let dependencies = FuminiwaApp.makeTestDependencies(
            userDefaults: defaults,
            configuration: configuration
        )
        #expect(dependencies.authSessionCoordinator == nil)
        #expect(dependencies.appleSignInCoordinator == nil)
        #expect(dependencies.appleAuthenticationOrchestrator == nil)
        let state = AppState(
            dependencies: dependencies
        )

        #expect(await state.configureSnapshotSyncV2(using: dependencies.snapshotSyncV2Factory))
        await state.bootstrap()
        state.markDocumentDirty()
        #expect(await state.saveNow())

        let application = try #require(state.snapshotSyncV2Application)
        let workID = try #require(state.currentSnapshotSyncV2WorkID)
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

        #expect(await state.saveNow())
        await Task.yield()

        let after = try sqliteInventory(at: productionStoreURL)
        #expect(after == before)
        #expect(await configuration.remote.recordedOperations().count == fakeCallsBeforeNoOpSave)
        #expect(
            UserDefaults.standard.string(forKey: "fuminiwa.syncServerURL")
                == productionEndpointBefore
        )
    }

    private func sqliteInventory(at url: URL) throws -> SQLiteInventory {
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
                SQLiteFileSignature(
                    exists: attributes != nil,
                    size: attributes?[.size] as? UInt64,
                    modificationDate: attributes?[.modificationDate] as? Date
                )
            )
        })
        return SQLiteInventory(files: files)
    }
}

private struct SQLiteInventory: Equatable {
    let files: [String: SQLiteFileSignature]
}

private struct SQLiteFileSignature: Equatable {
    let exists: Bool
    let size: UInt64?
    let modificationDate: Date?
}
