import Foundation
import NovelAuth
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Suite("Snapshot Sync v2 runtime isolation")
struct RuntimeIsolationTests {
    @Test("test runtimes receive distinct UUID temporary roots")
    func rootsArePhysicallyDistinct() throws {
        let first = try TestRuntimeConfiguration()
        let second = try TestRuntimeConfiguration()

        #expect(first.localRoot.url != second.localRoot.url)
        #expect(first.localRoot.runID != second.localRoot.runID)
        #expect(first.localRoot.url.path.hasPrefix(
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        ))
        #expect(first.defaults.suiteName != second.defaults.suiteName)
    }

    @Test("test root rejects a symlinked ancestor")
    func symlinkedAncestorIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-v2-root-test-\(UUID())")
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        #expect(throws: SyncV2ApplicationError.invalidRuntimeMode) {
            try TestLocalRoot(baseDirectory: linked, runID: UUID())
        }
    }

    @Test("test root rejects a symlinked destination child")
    func symlinkedDestinationIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-v2-child-test-\(UUID())")
        let target = root.appendingPathComponent("target", isDirectory: true)
        let child = root.appendingPathComponent(
            "FUMINIWA-SnapshotSyncV2-Tests",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: target)

        #expect(throws: SyncV2ApplicationError.invalidRuntimeMode) {
            try TestLocalRoot(baseDirectory: root, runID: UUID())
        }
    }

    @Test("production root rejects an app-controlled base alias")
    func productionRootRejectsAppControlledAlias() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-v2-production-root-\(UUID())")
        let real = parent.appendingPathComponent("real", isDirectory: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        #expect(throws: SyncV2ApplicationError.invalidRuntimeMode) {
            try ProductionLocalRoot(applicationSupportDirectory: alias)
        }
    }

    @Test("production root accepts the OS var alias")
    func productionRootAcceptsOSVarAlias() throws {
        let root = try ProductionLocalRoot(
            applicationSupportDirectory: URL(fileURLWithPath: "/var/tmp", isDirectory: true)
        )

        #expect(
            root.url.path == "/var/tmp/FUMINIWA/SnapshotSyncV2" ||
                root.url.path == "/private/var/tmp/FUMINIWA/SnapshotSyncV2"
        )
    }

    @Test("preview is read-only and creates no local root")
    func previewPerformsNoLocalIO() async throws {
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-v2-preview-sentinel-\(UUID())")
        let before = FileManager.default.fileExists(atPath: sentinel.path)
        let app = try await SnapshotSyncV2Runtime.makeApplication(
            mode: .preview(PreviewRuntimeConfiguration())
        )

        await #expect(throws: SyncV2ApplicationError.previewReadOnly) {
            try await app.checkpoint(
                workID: WorkID(UUID()),
                document: applicationTestDocument(),
                reason: .explicit,
                documentCreatedAt: applicationTestCreatedAt
            )
        }
        #expect(try await app.library().items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sentinel.path) == before)
    }

    @Test("production configuration requires the injected document gate")
    func productionRequiresDocumentGate() throws {
        let origin = try ProductionHTTPSOrigin(
            url: #require(URL(string: "https://sync.example.test"))
        )
        let gate = InMemorySyncV2DocumentGate()
        let configuration = try ProductionRuntimeConfiguration(
            origin: origin,
            documentGate: gate,
            clientVersion: "1.0.0",
            clientPlatform: .macos
        )
        #expect(configuration.documentGate != nil)
    }

    @Test("incompatible production database is quarantined before fresh bootstrap")
    func incompatibleProductionDatabaseStartsFresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-v2-production-reset-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("snapshot-sync-v2.sqlite"))

        let freshStore = try ProductionStoreFactory.openProduction(root: root)
        #expect(try await freshStore.listWorks(scope: .unbound).isEmpty)
        #expect(try await freshStore.schemaVersionAndChecksum().0 == "2")

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let quarantine = try #require(entries.first { url in
            url.lastPathComponent.hasPrefix("snapshot-sync-v2.sqlite.incompatible-")
        })
        #expect(
            try quarantine.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        )
        #expect(
            FileManager.default.fileExists(
                atPath: quarantine.appendingPathComponent("snapshot-sync-v2.sqlite").path
            )
        )
        await freshStore.close()
    }

    @Test("orphaned SQLite sidecars are quarantined before fresh bootstrap")
    func orphanedProductionSidecarsStartFresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-v2-orphaned-sidecars-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data(suffix.utf8).write(
                to: root.appendingPathComponent("snapshot-sync-v2.sqlite" + suffix)
            )
        }

        let freshStore = try ProductionStoreFactory.openProduction(root: root)
        #expect(try await freshStore.listWorks(scope: .unbound).isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let quarantine = try #require(entries.first { url in
            url.lastPathComponent.hasPrefix("snapshot-sync-v2.sqlite.incompatible-")
        })
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(
                FileManager.default.fileExists(
                    atPath: quarantine.appendingPathComponent(
                        "snapshot-sync-v2.sqlite" + suffix
                    ).path
                )
            )
        }
        await freshStore.close()
    }

    @Test("runtime identity mismatch cannot construct the application")
    func compositionMismatchIsRejected() throws {
        let state = InMemorySyncV2RuntimeState()
        let remote = ApplicationTestRemote([.failure(.offline)])
        let configuration = try TestRuntimeConfiguration()

        #expect(throws: SyncV2ApplicationError.invalidRuntimeMode) {
            try SyncV2Application(
                mode: .test(configuration),
                composition: applicationTestComposition(
                    state: state,
                    remote: remote,
                    identity: .preview
                )
            )
        }
    }

    @Test("application exposes no public dependency bypass initializer")
    func publicBypassDoesNotExist() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NovelSyncV2Application/SyncV2Application.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let actorBody = try #require(
            text.components(separatedBy: "public actor SyncV2Application {").last?
                .components(separatedBy: "\nextension SyncV2Application").first
        )
        #expect(!actorBody.contains("public init("))
        #expect(actorBody.contains("package init("))
    }

    @Test("pending and syncing have distinct shared Japanese labels")
    func sharedWordingDistinguishesWaitingFromActiveSync() {
        #expect(SyncV2RemoteProgress.pending.japaneseLabel == "同期待ち")
        #expect(
            SyncV2RemoteProgress.syncing(operationID: UUID()).japaneseLabel ==
                "同期中"
        )
    }

    @Test(
        "scope lookup never converts corrupt or foreign local state into a new work",
        arguments: [
            SyncV2StoreError.schemaMismatch,
            SyncV2StoreError.invalidSnapshot,
            SyncV2StoreError.accountMismatch
        ]
    )
    func unsafeStoreErrorIsNotWorkNotFound(
        storeError: SyncV2StoreError
    ) async {
        let resolver = ProductionScopeResolver(
            vault: InMemoryAuthSessionVault(),
            store: FailingScopeStore(error: storeError)
        )

        do {
            _ = try await resolver.scopeForCheckpoint(workID: WorkID(UUID()))
            Issue.record("unsafe Store error was treated as a new Work")
        } catch let received as SyncV2StoreError {
            #expect(received == storeError)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private struct FileInventory: Equatable {
    let exists: Bool
    let entries: [String]
    let databaseSize: UInt64?
}

private func fileInventory(at root: URL) -> FileInventory {
    let manager = FileManager.default
    let exists = manager.fileExists(atPath: root.path)
    let entries = (try? manager.contentsOfDirectory(atPath: root.path).sorted()) ?? []
    let database = root.appendingPathComponent("snapshot-sync-v2.sqlite")
    let attributes = try? manager.attributesOfItem(atPath: database.path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value
    return FileInventory(exists: exists, entries: entries, databaseSize: size)
}

private actor FailingScopeStore: ProductionScopeStore {
    let error: SyncV2StoreError

    init(error: SyncV2StoreError) {
        self.error = error
    }

    func open(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2OpenResult {
        _ = workID
        _ = scope
        throw error
    }
}
