import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import Testing

@MainActor
struct IOSSnapshotSyncV2PortableBoundaryTests {
    @Test("競合選択は新しいcheckpointやintentを作らない")
    func conflictSelectionDoesNotCheckpointAgain() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            guard let application = store.snapshotSyncV2Application,
                  let workID = store.syncV2ActiveWorkID,
                  let beforeState = await application.uiState(workID: workID),
                  case let .saved(generation, snapshotID) = beforeState.localDurability else {
                Issue.record("v2 work was not durably checkpointed")
                return
            }
            #expect(await store.refreshSnapshotHistory(for: workID))
            let beforeLocalHistoryCount = store.syncV2HistoryItems.count(where: {
                $0.source == .local
            })
            let conflict = SyncV2ConflictProjection(
                conflictID: UUID(),
                revision: 1,
                baseSnapshotID: nil,
                localSnapshotID: snapshotID,
                remoteSnapshotID: SnapshotID(data: Data("remote".utf8)),
                sourceGeneration: generation
            )
            // The UI projection is durable in production; this fixture models a
            // rendered inbox while the test runtime itself has no remote conflict.
            store.snapshotSyncState = SyncUIState(
                workID: workID,
                localDurability: beforeState.localDurability,
                remoteProgress: .needsChoice,
                conflict: conflict,
                lastTypedResult: .conflictPending
            )
            store.snapshotSyncConflict = conflict

            #expect(await store.resolveSnapshotSyncV2Conflict(using: .useServer) == false)
            let afterState = await application.uiState(workID: workID)
            #expect(afterState?.localDurability == beforeState.localDurability)
            #expect(await store.refreshSnapshotHistory(for: workID))
            #expect(store.syncV2HistoryItems.count(where: { $0.source == .local }) == beforeLocalHistoryCount)
        }
    }

    @Test("import uses manifest createdAt and archives opaque package resources")
    func importUsesPortableMetadataAndArchivesOpaqueResources() async throws {
        try await withEnvironment { environment in
            let source = environment.root
                .deletingLastPathComponent()
                .appendingPathComponent("portable-source-\(UUID().uuidString).novelpkg", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: source) }
            let repository = NovelpkgRepository()
            try await repository.save(NovelDocument.newDocument(), to: source)

            let createdAtString = "2021-05-06T07:08:09.123Z"
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expectedCreatedAt = try #require(formatter.date(from: createdAtString))
            let expectedCanonicalCreatedAt = Date(
                timeIntervalSince1970: expectedCreatedAt.timeIntervalSince1970.rounded(.down)
            )
            var manifest = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: source.appendingPathComponent("manifest.json"))
                ) as? [String: Any]
            )
            manifest["createdAt"] = createdAtString
            try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys, .prettyPrinted]
            ).write(to: source.appendingPathComponent("manifest.json"))
            let opaqueBytes = Data("opaque package resource".utf8)
            try opaqueBytes.write(to: source.appendingPathComponent("opaque-resource.bin"))
            let expectedResources = [PortableResource(
                pathComponents: ["opaque-resource.bin"],
                kind: .regularFile,
                bytes: opaqueBytes
            )]

            let importedWorkID: WorkID
            do {
                let store = IOSDocumentStore(
                    userDefaults: environment.defaults,
                    libraryRoot: environment.root
                )
                await store.bootstrap()
                #expect(await store.importPackage(from: source))
                #expect(store.documentCreatedAt == expectedCanonicalCreatedAt)
                #expect(store.syncV2PortableResources == expectedResources)
                importedWorkID = try #require(store.syncV2ActiveWorkID)
            }

            // Drop the test composition so the next store opens the persisted
            // SQLite file instead of reusing the first application instance.
            await environment.releaseApplication()

            do {
                let reopenedStore = IOSDocumentStore(
                    userDefaults: environment.defaults,
                    libraryRoot: environment.root
                )
                await reopenedStore.bootstrap()
                #expect(await reopenedStore.openSnapshotSyncV2(workID: importedWorkID.rawValue))
                #expect(reopenedStore.documentCreatedAt == expectedCanonicalCreatedAt)
                #expect(reopenedStore.syncV2PortableResources == expectedResources)

                await reopenedStore.requestExport()
                let exported = try #require(reopenedStore.pendingExportURL)
                let exportedPortable = try await SyncV2PortableBridge()
                    .importExplicitPackage(from: exported)
                #expect(exportedPortable.documentCreatedAt == expectedCanonicalCreatedAt)
                #expect(exportedPortable.resources == expectedResources)
                reopenedStore.dismissExport()
            }

            let archiveRoot = environment.root
                .appendingPathComponent("Legacy", isDirectory: true)
                .appendingPathComponent("ImportedPackages", isDirectory: true)
            let archives = try FileManager.default.contentsOfDirectory(
                at: archiveRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let archivedResource = try #require(
                archives.first?.appendingPathComponent("opaque-resource.bin")
            )
            let archivedBytes = try Data(contentsOf: archivedResource)
            #expect(archivedBytes == opaqueBytes)
        }
    }

    private func withEnvironment(
        _ body: (TestEnvironment) async throws -> Void
    ) async throws {
        let environment = makeEnvironment()
        do {
            try await body(environment)
        } catch {
            await environment.cleanup()
            throw error
        }
        await environment.cleanup()
        let key = environment.root.standardizedFileURL
        #expect(IOSDocumentStore.testRuntimeApplications[key] == nil)
        #expect(IOSDocumentStore.testRuntimeConfigurations[key] == nil)
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-v2-portable-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.v2.portable.\(id)"
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

    func releaseApplication() async {
        let key = root.standardizedFileURL
        if let application = IOSDocumentStore.testRuntimeApplications[key] {
            try? await application.resumePending()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        // Let in-flight actor calls release their SQLite handles before a
        // second composition opens the same isolated database.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func cleanup() async {
        let key = root.standardizedFileURL
        await releaseApplication()
        let configuration = IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: key)
        if let runtimeRoot = configuration?.localRoot.url {
            try? FileManager.default.removeItem(at: runtimeRoot)
        }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
