import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct RuntimeCompositionTests {
    @Test("macOS app test composition never creates HTTP transports")
    func appCompositionIsOffline() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWARuntimeComposition.\(UUID().uuidString)")
        )
        defaults.set("http://192.168.11.5:18080", forKey: "fuminiwa.syncServerURL")

        let dependencies = FuminiwaApp.makeDependencies(userDefaults: defaults)

        #expect(dependencies.defaultDocumentDirectoryName == "FUMINIWA-TestHost")
        #expect(dependencies.authSessionCoordinator == nil)
        #expect(dependencies.snapshotSyncTransport == nil)

        let state = AppState(
            dependencies: dependencies,
            initialStartupState: .ready
        )
        #expect(state.localSnapshotSyncWorker == nil)
    }

    @Test("AppState test save never opens the production SQLite store")
    func appStateSaveDoesNotTouchProductionStore() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWARuntimeSaveIsolation.\(UUID().uuidString)")
        )
        let productionStoreURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("library.sqlite")
        let before = try sqliteInventory(at: productionStoreURL)
        let state = AppState(
            dependencies: AppDependencies(
                repository: RuntimeNoopRepository(),
                userDefaults: defaults,
                fileManager: .default
            ),
            initialStartupState: .ready
        )

        let saved = await state.saveNow()
        #expect(saved)

        let testStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FUMINIWA-AppState-TestHost-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("library.sqlite")
        #expect(FileManager.default.fileExists(atPath: testStoreURL.path))
        #expect(testStoreURL.path.contains("FUMINIWA-AppState-TestHost-"))

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
        guard fileManager.fileExists(atPath: url.path) else {
            return SQLiteInventory(files: [:], counts: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            url.path,
            "SELECT (SELECT count(*) FROM works) || '|' || (SELECT count(*) FROM sync_intents);"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RuntimeCompositionTests", code: Int(process.terminationStatus))
        }
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = value.split(separator: "|").compactMap { Int($0) }
        guard counts.count == 2 else {
            throw NSError(domain: "RuntimeCompositionTests", code: 1)
        }
        let files = Dictionary(uniqueKeysWithValues: paths.map { path in
            let attributes = try? fileManager.attributesOfItem(atPath: path.path)
            return (
                path.lastPathComponent,
                SQLiteFileSignature(
                    exists: attributes != nil,
                    size: attributes?[.size] as? UInt64,
                    modificationDate: path == url
                        ? attributes?[.modificationDate] as? Date
                        : nil
                )
            )
        })
        return SQLiteInventory(files: files, counts: counts)
    }
}

private struct SQLiteInventory: Equatable {
    let files: [String: SQLiteFileSignature]
    let counts: [Int]?
}

private struct SQLiteFileSignature: Equatable {
    let exists: Bool
    let size: UInt64?
    let modificationDate: Date?
}

private struct RuntimeNoopRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
