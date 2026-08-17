import Foundation
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
            let effectiveAction = action.withGeneratedKeepBothIDs()
            let prepared = try await kernel.prepareConflict(effectiveAction)
            let openedWork: SyncV2OpenedWork?
            if let preparedWorkID = prepared.preparedWorkID {
                let opened = try await kernel.open(workID: preparedWorkID)
                guard opened.workID == preparedWorkID else {
                    throw SyncV2ApplicationError.workNotFound
                }
                recordOpened(opened)
                openedWork = opened
            } else {
                openedWork = nil
            }
            if prepared.noChanges {
                let state = setState(
                    workID: workID,
                    localDurability: states[workID]?.localDurability ?? .unsaved,
                    remoteProgress: .noChanges,
                    result: .noChanges,
                    conflict: .clear
                )
                return SyncV2OperationResult(
                    state: state,
                    typedResult: .noChanges,
                    openedWork: openedWork
                )
            }
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .pending,
                result: .queued
            )
            // Preparation (including keep-both clone creation) is complete
            // before this wake.  A stalled transport therefore cannot race
            // the local editor switch or put the clone at risk.
            scheduleWorker(for: workID)
            return SyncV2OperationResult(
                state: state,
                typedResult: .queued,
                openedWork: openedWork
            )
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

private extension SyncV2ConflictAction {
    func withGeneratedKeepBothIDs() -> SyncV2ConflictAction {
        guard choice == .keepBoth,
              newWorkID == nil || newDocumentID == nil else { return self }
        return SyncV2ConflictAction(
            workID: workID,
            conflictID: conflictID,
            revision: revision,
            baseSnapshotID: baseSnapshotID,
            localSnapshotID: localSnapshotID,
            remoteSnapshotID: remoteSnapshotID,
            sourceGeneration: sourceGeneration,
            choice: choice,
            commandID: commandID,
            inboxID: inboxID,
            newWorkID: newWorkID ?? WorkID(UUID()),
            newDocumentID: newDocumentID ?? DocumentID(UUID())
        )
    }
}
