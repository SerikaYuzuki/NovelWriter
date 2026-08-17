import Foundation
@testable import FUMINIWA
import NovelAuth
import NovelCore
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct RuntimeCompositionTests {
    @Test("macOS test compositionはproduction URLやHTTP transportを作らない")
    func appCompositionUsesIsolatedTestRuntime() throws {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWARuntimeComposition.\(UUID().uuidString)"))
        defaults.set("http://192.168.11.5:18080", forKey: FuminiwaRuntimeEnvironment.syncServerURLKey)

        let environment = FuminiwaRuntimeEnvironment(
            userDefaults: defaults,
            environment: [FuminiwaRuntimeEnvironment.testNetworkDisabledKey: "1"]
        )
        #expect(environment.isTestProcess)
        #expect(environment.syncServerURL == nil)

        let configuration = try TestRuntimeConfiguration()
        let dependencies = FuminiwaApp.makeTestDependencies(
            userDefaults: defaults,
            configuration: configuration
        )
        #expect(dependencies.defaultDocumentDirectoryName == "FUMINIWA-TestHost")
        #expect(dependencies.authSessionCoordinator == nil)
        #expect(dependencies.snapshotSyncV2Factory != nil)
    }

    @Test("AppState test saveはproduction SQLite rootを変更しない")
    func appStateSaveDoesNotTouchProductionStore() async throws {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWARuntimeSaveIsolation.\(UUID().uuidString)"))
        let productionStoreURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("SnapshotSyncV2", isDirectory: true)
            .appendingPathComponent("snapshot-sync-v2.sqlite")
        let before = try sqliteInventory(at: productionStoreURL)
        let configuration = try TestRuntimeConfiguration()
        let dependencies = FuminiwaApp.makeTestDependencies(
            userDefaults: defaults,
            configuration: configuration
        )
        let state = AppState(
            dependencies: dependencies
        )

        #expect(await state.configureSnapshotSyncV2(using: dependencies.snapshotSyncV2Factory))
        await state.bootstrap()
        state.markDocumentDirty()
        #expect(await state.saveNow())

        let after = try sqliteInventory(at: productionStoreURL)
        #expect(after == before)
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
