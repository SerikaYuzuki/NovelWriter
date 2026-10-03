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
        if let previous = conflictPreparations[workID],
           previous.conflictID == action.conflictID, previous.revision == action.revision {
            guard let state = lanes[workID]?.state?.projection else {
                throw SyncV2ApplicationError.staleConflictAction
            }
            return SyncV2OperationResult(state: state, typedResult: .staleConflictAction)
        }
        // Acquire before the kernel await; actor reentrancy must not queue a
        // second choice while the first transaction is still being prepared.
        conflictPreparations[workID] = action
        var committed = false
        defer {
            if !committed {
                conflictPreparations.removeValue(forKey: workID)
            }
        }
        do {
            let effectiveAction = action.withGeneratedKeepBothIDs()
            let prepared = try await kernel.prepareConflict(effectiveAction)
            committed = true
            let openedWork: SyncV2OpenedWork?
            if let preparedWorkID = prepared.preparedWorkID {
                let opened = try await kernel.open(workID: preparedWorkID)
                guard opened.workID == preparedWorkID else {
                    throw SyncV2ApplicationError.workNotFound
                }
                await copyWritingHistory(source: workID, destination: preparedWorkID)
                recordOpened(opened)
                openedWork = opened
            } else {
                openedWork = nil
            }
            if prepared.noChanges {
                let state = setState(
                    workID: workID,
                    localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
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
                localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                remoteProgress: .pending,
                result: .queued,
                conflict: .clear
            )
            // Preparation (including keep-both clone creation) is complete
            // before this wake.  Keep-both deliberately leaves the source
            // lane asleep so the caller can switch its editor first; the
            // caller resumes pending work after the local hand-off.
            if effectiveAction.choice != .keepBoth {
                scheduleWorker(for: workID)
            }
            return SyncV2OperationResult(
                state: state,
                typedResult: .queued,
                openedWork: openedWork
            )
        } catch SyncV2ApplicationError.staleConflictAction {
            let currentConflict = try await kernel.activeConflict(workID: workID)
            let state = setState(
                workID: workID,
                localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                remoteProgress: currentConflict == nil ? .pending : .needsChoice,
                result: .staleConflictAction,
                conflict: currentConflict.map(SyncV2ConflictUpdate.set) ?? .clear
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
        if try await kernel.snapshotAvailability(workID: workID, snapshotID: snapshotID) == .unfetched {
            prioritizeHistory(workID: workID)
            throw SyncV2Failure.retryable(.historyIncomplete)
        }
        let prepared = try await kernel.prepareRestore(
            SyncV2RestoreRequest(workID: workID, snapshotID: snapshotID)
        )
        guard !prepared.noChanges else {
            let state = setState(
                workID: workID,
                localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                remoteProgress: .noChanges,
                result: .noChanges
            )
            return SyncV2OperationResult(state: state, typedResult: .noChanges)
        }
        cancelLeafPromotion(workID: workID)
        let hasPendingRemoteIntent = prepared.intentID != nil
        let state = setState(
            workID: workID,
            localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
            remoteProgress: hasPendingRemoteIntent ? .pending : .authenticationRequired,
            result: .restored
        )
        if hasPendingRemoteIntent {
            scheduleWorker(for: workID)
        }
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

extension SyncV2Application {
    func hasPreparedConflict(workID: WorkID, conflict: SyncV2ConflictProjection) -> Bool {
        conflictPreparations[workID]?.conflictID == conflict.conflictID &&
            conflictPreparations[workID]?.revision == conflict.revision
    }
}
