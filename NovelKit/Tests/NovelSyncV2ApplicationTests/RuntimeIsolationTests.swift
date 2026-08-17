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

    @Test("production factory fails before opening or creating its SQLite root")
    func incompleteProductionIsFailClosedBeforeIO() async throws {
        let origin = try ProductionHTTPSOrigin(
            url: #require(URL(string: "https://sync.example.test"))
        )
        let configuration = try ProductionRuntimeConfiguration(origin: origin)
        let before = fileInventory(at: configuration.localRoot.url)

        await #expect(throws: SyncV2ApplicationError.productionRuntimeIncomplete) {
            try await SnapshotSyncV2Runtime.makeApplication(
                mode: .production(configuration)
            )
        }

        #expect(fileInventory(at: configuration.localRoot.url) == before)
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
