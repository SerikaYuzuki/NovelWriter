import Foundation
import NovelAuth
import NovelSyncV2Application
import NovelSyncV2Store

public enum SnapshotSyncV2Runtime {
    public static func makeApplication(
        mode: RuntimeMode
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
            let store = try ProductionStoreFactory.open(
                root: configuration.localRoot.url
            )
            let scope = ProductionScopeResolver(vault: configuration.vault, store: store)
            let remote: any SyncV2RemoteClient = if let origin = configuration.origin, let vault = configuration.vault {
                ProductionSyncV2RemoteClient(
                    origin: origin,
                    vault: vault,
                    clientVersion: configuration.clientVersion,
                    clientPlatform: configuration.clientPlatform
                )
            } else {
                OfflineProductionSyncV2RemoteClient()
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
        try await app.resumePending()
        return app
    }
}

private enum ProductionStoreFactory {
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
