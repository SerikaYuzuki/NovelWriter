import NovelSyncV2

public extension SyncV2Application {
    func resolveConflict(
        workID: WorkID,
        action: SyncV2ConflictAction
    ) async throws -> SyncV2OperationResult {
        guard runtimeIdentity != .preview else {
            throw SyncV2ApplicationError.previewReadOnly
        }
        guard action.workID == workID else {
            throw SyncV2ApplicationError.staleConflictAction
        }
        do {
            let prepared = try await kernel.prepareConflict(action)
            if prepared.noChanges {
                let state = setState(
                    workID: workID,
                    localDurability: states[workID]?.localDurability ?? .unsaved,
                    remoteProgress: .noChanges,
                    result: .noChanges,
                    conflict: .clear
                )
                return SyncV2OperationResult(state: state, typedResult: .noChanges)
            }
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .pending,
                result: .queued
            )
            scheduleWorker(for: workID)
            return SyncV2OperationResult(state: state, typedResult: .queued)
        } catch SyncV2ApplicationError.staleConflictAction {
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .needsChoice,
                result: .staleConflictAction
            )
            return SyncV2OperationResult(
                state: state,
                typedResult: .staleConflictAction
            )
        }
    }

    func restore(
        workID: WorkID,
        snapshotID: SnapshotID
    ) async throws -> SyncV2OperationResult {
        guard runtimeIdentity != .preview else {
            throw SyncV2ApplicationError.previewReadOnly
        }
        let prepared = try await kernel.prepareRestore(
            SyncV2RestoreRequest(workID: workID, snapshotID: snapshotID)
        )
        guard !prepared.noChanges else {
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .noChanges,
                result: .noChanges
            )
            return SyncV2OperationResult(state: state, typedResult: .noChanges)
        }
        let state = setState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: .pending,
            result: .restored
        )
        scheduleWorker(for: workID)
        return SyncV2OperationResult(state: state, typedResult: .restored)
    }
}
