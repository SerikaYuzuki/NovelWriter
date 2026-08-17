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
            let account = await configuration.vault.currentAccount()
            let state = InMemorySyncV2RuntimeState(account: account)
            composition = SyncV2RuntimeComposition(
                identity: .test,
                kernel: state,
                planner: state,
                remote: configuration.remote,
                gate: InMemorySyncV2DocumentGate(),
                library: state
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
            // The concrete Store/Auth/HTTP adapters compile in this target,
            // but the typed v2 upload/register/publish chain and the platform
            // DocumentOperationGate bridge are not complete yet. Fail before
            // opening or creating the production SQLite database.
            _ = configuration
            throw SyncV2ApplicationError.productionRuntimeIncomplete
        }
        return try SyncV2Application(mode: mode, composition: composition)
    }
}

private enum ProductionStoreFactory {
    static func open(root: URL) throws -> LocalSyncV2Store {
        let database = root.appendingPathComponent("snapshot-sync-v2.sqlite")
        let policy: V2StoreOpenPolicy = FileManager.default.fileExists(
            atPath: database.path
        ) ? .openExisting : .createNew
        return try LocalSyncV2Store(root: root, policy: policy)
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
