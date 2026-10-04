import NovelSyncV2
import NovelSyncV2Application

public extension ConflictCoordinator {
    /// Only the frozen source skips save; IME preparation and document gates
    /// remain platform responsibilities. A successful departure retires it.
    static func saveBeforeDeparture(
        currentWorkID: WorkID?, pendingDuplicateID: WorkID?, save: () async -> Bool
    ) async -> Bool {
        if let currentWorkID, let pendingDuplicateID, currentWorkID != pendingDuplicateID {
            return true
        }
        return await save()
    }

    func retryKeepBothAtPreparedBoundary(
        host: any WorkspaceHost, handoff: WorkspaceKeepBothHandoff,
        isCurrent: @escaping () -> Bool,
        install: (SyncV2OpenedWork, SyncV2ConflictAction) async -> Bool,
        project: (SyncUIState?) -> Void, resume: () async -> Void
    ) async throws -> Bool {
        let accepts = { !Task.isCancelled && handoff.context.isCurrent(host.operationContext) && isCurrent() }
        guard accepts(), let workID = handoff.action.newWorkID else { return false }
        do {
            let opened = try await openLocal(workID)
            guard accepts(), await installKeepBoth(host: host, handoff: handoff, opened: opened,
                                                   isCurrent: isCurrent, install: install, project: project) else { return false }
            await resume()
            return true
        } catch {
            guard accepts(), !(error is CancellationError) else { return false }
            throw error
        }
    }

    internal func installKeepBoth(
        host: any WorkspaceHost, handoff: WorkspaceKeepBothHandoff, opened: SyncV2OpenedWork,
        isCurrent: () -> Bool,
        install: (SyncV2OpenedWork, SyncV2ConflictAction) async -> Bool,
        project: (SyncUIState?) -> Void
    ) async -> Bool {
        let action = handoff.action, context = handoff.context
        guard !Task.isCancelled, context.isCurrent(host.operationContext), isCurrent(),
              let cloneID = action.newWorkID, cloneID != context.workID,
              let documentID = action.newDocumentID, opened.workID == cloneID,
              opened.document?.id == documentID.rawValue,
              await install(opened, action) else { return false }
        let installed = host.operationContext
        guard !Task.isCancelled, installed.workID == cloneID,
              installed.session?.workID == cloneID, installed.session?.documentID == documentID.rawValue,
              installed.account == context.account else { return false }
        let state = await uiState(cloneID)
        guard !Task.isCancelled, installed.isCurrent(host.operationContext) else { return false }
        project(state)
        return true
    }
}
