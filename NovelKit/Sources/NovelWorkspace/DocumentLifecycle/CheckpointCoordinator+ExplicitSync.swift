import NovelSyncV2Application

public extension CheckpointCoordinator {
    /// Gate/IME and local promotion are injected by the platform. The remote
    /// request is allowed only after that local boundary successfully completes.
    func explicitlySync(
        host: any WorkspaceHost,
        permitsRemoteCompletion: () -> Bool = { true },
        saveLocally: (WorkspaceOperationContext) async -> Bool,
        didSave: () -> Void = {},
        requestsRemote: () -> Bool = { true },
        adoptionContext: (() -> WorkspaceOperationContext?)? = nil,
        didQueue: (SyncV2OperationResult, WorkspaceOperationContext?) async -> Bool,
        localOnly: () async -> Void = {},
        failed: () async -> Void
    ) async -> Bool {
        let context = Self.context(of: host)
        guard let workID = context.workID, await saveLocally(context),
              Self.matches(context, host: host), permitsRemoteCompletion() else { return false }
        didSave()
        guard requestsRemote() else {
            await localOnly()
            return true
        }
        // Freeze the clean edit generation for the platform's adoption hook.
        let cleanContext = adoptionContext.map { $0() } ?? host.operationContext
        do {
            let result = try await synchronize(workID)
            guard Self.matches(context, host: host), permitsRemoteCompletion() else { return false }
            return await didQueue(result, cleanContext)
        } catch {
            guard Self.matches(context, host: host), permitsRemoteCompletion() else { return false }
            await failed()
            return false
        }
    }
}
