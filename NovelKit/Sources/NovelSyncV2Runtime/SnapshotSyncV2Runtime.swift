import Foundation
import NovelAuth
import NovelSyncV2Application
import NovelSyncV2Store
import OSLog

private let snapshotSyncV2RuntimeLogger = Logger(
    subsystem: "dev.serikayuzuki.fuminiwa",
    category: "startup"
)

public enum SnapshotSyncV2Runtime {
    public static func makeProductionDocumentGate() -> ProductionDocumentGate {
        ProductionDocumentGate()
    }

    public static func makeApplication(
        mode: RuntimeMode
    ) async throws -> SyncV2Application {
        try await makeApplication(mode: mode, resumeOnLaunch: true)
    }

    static func makeApplicationForTesting(
        mode: RuntimeMode,
        resumeOnLaunch: Bool
    ) async throws -> SyncV2Application {
        try await makeApplication(mode: mode, resumeOnLaunch: resumeOnLaunch)
    }

    private static func makeApplication(
        mode: RuntimeMode,
        resumeOnLaunch: Bool
    ) async throws -> SyncV2Application {
        let composition: SyncV2RuntimeComposition
        switch mode {
        case let .test(configuration):
            try FileManager.default.createDirectory(
                at: configuration.localRoot.url,
                withIntermediateDirectories: true
            )
            let store = try ProductionStoreFactory.open(
                root: configuration.localRoot.url,
                policy: .createNew
            )
            let scope = TestScopeResolver(vault: configuration.vault, store: store)
            let remote = configuration.remote
            let kernel = ProductionSyncV2Kernel(store: store, scope: scope, remote: remote)
            let planner = ProductionSyncV2Planner(store: store, scope: scope)
            composition = SyncV2RuntimeComposition(
                identity: .test,
                kernel: kernel,
                planner: planner,
                remote: remote,
                gate: InMemorySyncV2DocumentGate(),
                library: kernel
            )
        case .preview:
            let state = InMemorySyncV2RuntimeState(readOnly: true)
            composition = SyncV2RuntimeComposition(
                identity: .preview,
                kernel: state,
                planner: state,
                remote: PreviewSyncV2RemoteClient(),
                gate: InMemorySyncV2DocumentGate(),
                library: state
            )
        case let .production(configuration):
            guard let documentGate = configuration.documentGate else {
                throw SyncV2ApplicationError.invalidRuntimeMode
            }
            try FileManager.default.createDirectory(
                at: configuration.localRoot.url,
                withIntermediateDirectories: true
            )
            let store = try ProductionStoreFactory.openProduction(
                root: configuration.localRoot.url
            )
            let scope = ProductionScopeResolver(vault: configuration.vault, store: store)
            let remote: any SyncV2RemoteClient
            if let origin = configuration.origin,
               let vault = configuration.vault,
               let coordinator = configuration.authSessionCoordinator {
                let provider = ProductionSyncV2SessionProvider(
                    vault: vault,
                    coordinator: coordinator,
                    proactiveRefresh: true
                )
                remote = ProductionSyncV2RemoteClient(
                    origin: origin,
                    vault: vault,
                    clientVersion: configuration.clientVersion,
                    clientPlatform: configuration.clientPlatform,
                    sessionProvider: provider
                )
            } else {
                remote = OfflineProductionSyncV2RemoteClient()
            }
            let kernel = ProductionSyncV2Kernel(store: store, scope: scope, remote: remote)
            let planner = ProductionSyncV2Planner(store: store, scope: scope)
            composition = SyncV2RuntimeComposition(
                identity: .production,
                kernel: kernel,
                planner: planner,
                remote: remote,
                gate: documentGate,
                library: kernel
            )
        }
        let app = try SyncV2Application(mode: mode, composition: composition)
        do {
            if resumeOnLaunch {
                try await app.resumePending()
            }
        } catch {
            let errorType = snapshotSyncV2StartupErrorLabel(error)
            snapshotSyncV2RuntimeLogger.error(
                "Snapshot Sync v2 resume failed (error type: \(errorType, privacy: .public))"
            )
            throw error
        }
        return app
    }
}

private func snapshotSyncV2StartupErrorLabel(_ error: any Error) -> String {
    #if canImport(Security)
    if let keychainError = error as? KeychainAuthError {
        return switch keychainError {
        case .invalidRecord:
            "NovelAuth.KeychainAuthError.invalidRecord"
        case let .status(status):
            "NovelAuth.KeychainAuthError.status(\(status))"
        }
    }
    #endif
    return String(reflecting: type(of: error))
}

enum ProductionStoreFactory {
    /// Opens the production database, quarantining only an incompatible
    /// existing schema.  A stale v2 database is not a migration source for
    /// the current runtime; keep it recoverable and start with an empty store.
    static func openProduction(root: URL) throws -> LocalSyncV2Store {
        if !databaseExists(at: root), hasOrphanedSidecar(at: root) {
            try quarantineIncompatibleDatabase(at: root)
        }
        do {
            return try open(root: root)
        } catch SyncV2StoreError.schemaMismatch {
            try quarantineIncompatibleDatabase(at: root)
            return try LocalSyncV2Store(root: root, policy: .createNew)
        }
    }

    static func open(
        root: URL,
        policy: V2StoreOpenPolicy = .createNew
    ) throws -> LocalSyncV2Store {
        let database = root.appendingPathComponent("snapshot-sync-v2.sqlite")
        let actualPolicy: V2StoreOpenPolicy = FileManager.default.fileExists(
            atPath: database.path
        ) ? .openExisting : policy
        return try LocalSyncV2Store(root: root, policy: actualPolicy)
    }

    static func quarantineIncompatibleDatabase(at root: URL) throws {
        let fileManager = FileManager.default
        let databaseName = "snapshot-sync-v2.sqlite"
        let quarantine = root.appendingPathComponent(
            "\(databaseName).incompatible-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: false)
        do {
            for suffix in databaseArtifactSuffixes {
                let source = root.appendingPathComponent(databaseName + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(
                    at: source,
                    to: quarantine.appendingPathComponent(databaseName + suffix)
                )
            }
        } catch {
            // Do not remove a partially populated quarantine.  A failed move
            // must never turn an incompatible database into data loss: the
            // already moved files remain recoverable for a later repair.
            throw error
        }
    }

    private static let databaseArtifactSuffixes = ["", "-wal", "-shm", "-journal"]

    private static func databaseExists(at root: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("snapshot-sync-v2.sqlite").path
        )
    }

    private static func hasOrphanedSidecar(at root: URL) -> Bool {
        databaseArtifactSuffixes.dropFirst().contains { suffix in
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("snapshot-sync-v2.sqlite" + suffix).path
            )
        }
    }
}

private actor PreviewSyncV2RemoteClient: SyncV2RemoteClient {
    func execute(
        _ operation: SyncV2RemoteOperation
    ) async throws -> SyncV2RemoteExecution {
        _ = operation
        throw SyncV2ApplicationError.previewReadOnly
    }
}

private actor OfflineProductionSyncV2RemoteClient: SyncV2RemoteClient {
    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        _ = operation
        throw SyncV2Failure.authenticationRequired
    }
}
