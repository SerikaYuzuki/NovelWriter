import Foundation
import NovelAuth
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Snapshot Sync v2 fresh production bootstrap")
struct ProductionFreshResumeTests {
    @Test("fresh production composition resumes with no vault session")
    func freshProductionCompositionResumesWithoutSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fuminiwa-v2-production-resume-\(UUID())",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let store = try ProductionStoreFactory.openProduction(root: root)
        let vault = InMemoryAuthSessionVault()
        let scope = ProductionScopeResolver(vault: vault, store: store)
        let remote = ApplicationTestRemote([.failure(.offline)])
        let kernel = ProductionSyncV2Kernel(
            store: store,
            scope: scope,
            remote: remote
        )
        let planner = ProductionSyncV2Planner(store: store, scope: scope)
        let configuration = try ProductionRuntimeConfiguration(
            vault: vault,
            documentGate: InMemorySyncV2DocumentGate(),
            clientVersion: "1.0.0",
            clientPlatform: .macos
        )
        let app = try SyncV2Application(
            mode: .production(configuration),
            composition: SyncV2RuntimeComposition(
                identity: .production,
                kernel: kernel,
                planner: planner,
                remote: remote,
                gate: InMemorySyncV2DocumentGate(),
                library: kernel
            )
        )

        try await app.resumePending()
        #expect(try await app.library().items.isEmpty)
        await store.close()
    }

    #if canImport(Security)
    @Test("fresh production composition resumes with an empty Keychain vault")
    func freshProductionCompositionResumesWithEmptyKeychain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fuminiwa-v2-production-keychain-\(UUID())",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let store = try ProductionStoreFactory.openProduction(root: root)
        let vault = KeychainAuthSessionVault(
            service: "jp.fuminiwa.test.empty-\(UUID().uuidString)",
            account: "session"
        )
        let scope = ProductionScopeResolver(vault: vault, store: store)
        let remote = ApplicationTestRemote([.failure(.offline)])
        let kernel = ProductionSyncV2Kernel(
            store: store,
            scope: scope,
            remote: remote
        )
        let planner = ProductionSyncV2Planner(store: store, scope: scope)
        let configuration = try ProductionRuntimeConfiguration(
            vault: vault,
            documentGate: InMemorySyncV2DocumentGate(),
            clientVersion: "1.0.0",
            clientPlatform: .macos
        )
        let app = try SyncV2Application(
            mode: .production(configuration),
            composition: SyncV2RuntimeComposition(
                identity: .production,
                kernel: kernel,
                planner: planner,
                remote: remote,
                gate: InMemorySyncV2DocumentGate(),
                library: kernel
            )
        )

        try await app.resumePending()
        #expect(try await app.library().items.isEmpty)
        await store.close()
    }
    #endif
}
