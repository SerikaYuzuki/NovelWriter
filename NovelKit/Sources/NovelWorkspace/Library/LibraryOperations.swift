import NovelSyncV2
import NovelSyncV2Application

/// Application calls are injectable for focused tests. Background execution time
/// wraps just the two downloads on iOS, without moving platform APIs into core.
@MainActor
public struct LibraryOperations {
    public var library: () async throws -> SyncV2LibraryProjection
    public var pendingDeletionIDs: () async throws -> Set<WorkID>
    public var deletedIDs: () async throws -> Set<WorkID>
    public var catalog: (String?, Int) async throws -> SyncV2RemoteCatalogPage
    public var importStates: () async -> (phases: [WorkID: ImportPhase], failures: [WorkID: SyncV2Failure])
    public var cancelImport: (WorkID) async -> Void
    public var downloadForRename: (WorkID) async throws -> Void
    public var prefetch: (WorkID) async throws -> Void
    public var rename: (WorkID, String) async throws -> Void
    public var reserveDeletion: (WorkID) async throws -> Void
    public var delete: (WorkID) async throws -> Void

    public init(
        library: @escaping () async throws -> SyncV2LibraryProjection,
        pendingDeletionIDs: @escaping () async throws -> Set<WorkID>,
        deletedIDs: @escaping () async throws -> Set<WorkID>,
        catalog: @escaping (String?, Int) async throws -> SyncV2RemoteCatalogPage,
        importStates: @escaping () async -> (phases: [WorkID: ImportPhase], failures: [WorkID: SyncV2Failure]),
        cancelImport: @escaping (WorkID) async -> Void,
        downloadForRename: @escaping (WorkID) async throws -> Void,
        prefetch: @escaping (WorkID) async throws -> Void,
        rename: @escaping (WorkID, String) async throws -> Void,
        reserveDeletion: @escaping (WorkID) async throws -> Void,
        delete: @escaping (WorkID) async throws -> Void
    ) {
        self.library = library
        self.pendingDeletionIDs = pendingDeletionIDs
        self.deletedIDs = deletedIDs
        self.catalog = catalog
        self.importStates = importStates
        self.cancelImport = cancelImport
        self.downloadForRename = downloadForRename
        self.prefetch = prefetch
        self.rename = rename
        self.reserveDeletion = reserveDeletion
        self.delete = delete
    }

    public init(application: SyncV2Application) {
        self.init(
            library: { try await application.library() },
            pendingDeletionIDs: { try await application.pendingDeletionWorkIDs() },
            deletedIDs: { try await application.deletedWorkIDs() },
            catalog: { try await application.refreshRemoteCatalog(cursor: $0, pageSize: $1) },
            importStates: { await application.importStates() },
            cancelImport: { await application.cancelImport(workID: $0) },
            downloadForRename: { _ = try await application.open(workID: $0) },
            prefetch: { try await application.prefetch(workID: $0) },
            rename: { _ = try await application.renameLocalWork(workID: $0, title: $1) },
            reserveDeletion: { _ = try await application.prepareWorkDeletion(workID: $0) },
            delete: { try await application.deleteWork(workID: $0) }
        )
    }
}
