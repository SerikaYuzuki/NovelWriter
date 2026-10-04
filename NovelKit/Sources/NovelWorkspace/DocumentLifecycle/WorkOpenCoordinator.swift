import NovelSyncV2
import NovelSyncV2Application

/// Local reads and remote downloads share identity validation, but downloads run
/// outside the platform document gate. Only install crosses the prepared boundary.
@MainActor
public struct WorkOpenCoordinator {
    public var openLocal: (WorkID) async throws -> SyncV2OpenedWork
    public var download: (WorkID) async throws -> SyncV2OpenedWork
    public var isCurrentLocalVersion: (SyncV2OpenedWork) async throws -> Bool
    public var beginSession: (WorkID) async -> DocumentSessionToken
    public var uiState: (WorkID) async -> SyncUIState?

    public init(application: SyncV2Application) {
        openLocal = { try await application.openLocal(workID: $0) }
        download = { try await application.open(workID: $0) }
        isCurrentLocalVersion = { try await application.isCurrentLocalVersion($0) }
        beginSession = { await application.beginSession(workID: $0) }
        uiState = { await application.uiState(workID: $0) }
    }

    public init(
        openLocal: @escaping (WorkID) async throws -> SyncV2OpenedWork,
        download: @escaping (WorkID) async throws -> SyncV2OpenedWork,
        isCurrentLocalVersion: @escaping (SyncV2OpenedWork) async throws -> Bool,
        beginSession: @escaping (WorkID) async -> DocumentSessionToken,
        uiState: @escaping (WorkID) async -> SyncUIState? = { _ in nil }
    ) {
        self.openLocal = openLocal
        self.download = download
        self.isCurrentLocalVersion = isCurrentLocalVersion
        self.beginSession = beginSession
        self.uiState = uiState
    }

    public func readLocal(workID: WorkID, isCurrent: () -> Bool) async throws -> SyncV2OpenedWork? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        do {
            let opened = try await openLocal(workID)
            guard !Task.isCancelled, isCurrent() else { return nil }
            try Self.validate(opened, workID: workID)
            return opened
        } catch {
            guard !Task.isCancelled, isCurrent() else { return nil }
            throw error
        }
    }

    public func downloadRemoteOnly(
        workID: WorkID, isCurrent: () -> Bool, opening: () -> Void
    ) async throws -> SyncV2OpenedWork? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        let opened = try await download(workID)
        guard !Task.isCancelled, isCurrent() else { return nil }
        try Self.validate(opened, workID: workID)
        opening()
        return opened
    }

    /// Caller holds its document gate after IME commit and local save. Capture
    /// editing generation here, so edits during download remain legitimate while
    /// edits during a suspended install invalidate that completion.
    public func installAtPreparedBoundary(
        _ opened: SyncV2OpenedWork, workID: WorkID, host: any WorkspaceHost,
        verifiesLocalVersion: Bool = false, createsSession: Bool = false,
        isCurrent: @escaping () -> Bool = { true },
        install: (SyncV2OpenedWork, DocumentSessionToken?) -> Bool,
        project: (SyncUIState?) -> Void = { _ in }
    ) async throws -> Bool {
        let context = host.operationContext
        let accepts = { !Task.isCancelled && context.isCurrent(host.operationContext) && isCurrent() }
        do {
            guard accepts() else { return false }
            try Self.validate(opened, workID: workID)
            if verifiesLocalVersion {
                guard try await isCurrentLocalVersion(opened), accepts() else { return false }
            }
            let session = createsSession ? await beginSession(workID) : nil
            guard accepts(), install(opened, session) else { return false }
            let installedContext = host.operationContext
            let state = await uiState(workID)
            guard !Task.isCancelled, installedContext.isCurrent(host.operationContext),
                  host.operationContext.workID == workID else { return false }
            project(state)
            return true
        } catch {
            guard accepts() else { return false }
            throw error
        }
    }

    private static func validate(_ opened: SyncV2OpenedWork, workID: WorkID) throws {
        guard opened.workID == workID else { throw SyncV2ApplicationError.safeBoundaryRejected }
        guard opened.document != nil else { throw SyncV2ApplicationError.safeBoundaryRejected }
    }
}
