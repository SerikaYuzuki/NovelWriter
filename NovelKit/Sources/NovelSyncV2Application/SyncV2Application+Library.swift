import Foundation
import NovelSyncV2

public extension SyncV2Application {
    /// Opens only the durable local state.
    ///
    /// This is the launch/editor boundary: it never consults the catalog or
    /// downloads a remote-only work. Remote-only fallback belongs exclusively
    /// to `open(workID:)`, which is an explicit remote-capable operation.
    func openLocal(workID: WorkID) async throws -> SyncV2OpenedWork {
        let opened = try await kernel.open(workID: workID)
        guard opened.document != nil || opened.generation != 0 || opened.snapshotID != nil else {
            throw SyncV2ApplicationError.workNotFound
        }
        if runtimeIdentity != .preview {
            _ = try await kernel.promoteCurrentLeaf(workID: workID)
            cancelLeafPromotion(workID: workID)
        }
        recordOpened(opened)
        let activeConflict = try await kernel.activeConflict(workID: workID)
        let adoption = try await kernel.pendingAdoption(workID: workID)
        if let adoption {
            setState(
                workID: workID,
                localDurability: durability(for: opened),
                remoteProgress: .readyForSafeAdoption(
                    inboxID: adoption.inboxID
                ),
                result: .adoptionPending,
                conflict: .clear
            )
        } else if let conflict = activeConflict {
            setState(
                workID: workID,
                localDurability: durability(for: opened),
                remoteProgress: .needsChoice,
                result: .conflictPending,
                conflict: .set(conflict)
            )
        }
        // A verified incoming version must cross the editor gate before a
        // planner can publish another local command. Reopening this work is
        // not a reason to overwrite the adoption projection with worker state.
        if adoption == nil {
            scheduleWorker(for: workID)
        }
        return opened
    }

    func prefetch(workID: WorkID) async throws {
        _ = try await obtainWork(workID: workID, opening: false)
    }

    func importStates() -> (phases: [WorkID: ImportPhase], failures: [WorkID: SyncV2Failure]) {
        (laneValues(\.importProgress).mapValues { $0.value }, laneValues(\.importFailure))
    }

    func importUpdates(workID: WorkID) -> AsyncStream<ImportPhase>? {
        lanes[workID, default: WorkLane()].importProgress?.updates
    }

    func lastImportFailure(workID: WorkID) -> SyncV2Failure? {
        lanes[workID, default: WorkLane()].importFailure
    }

    func cancelImport(workID: WorkID) async {
        guard let task = lanes[workID, default: WorkLane()].remoteOnlyOpen else { return }
        task.cancel()
        _ = try? await task.value
    }

    func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        try await obtainWork(workID: workID, opening: true)
    }

    private func obtainWork(workID: WorkID, opening: Bool) async throws -> SyncV2OpenedWork {
        try Task.checkCancellation()
        if let task = lanes[workID, default: WorkLane()].remoteOnlyOpen {
            guard remoteSchedulingSuspensions.isEmpty else { throw SyncV2Failure.accountFenceChanged }
            if opening {
                setLaneFlag(\.shouldOpenImportedWork, workID: workID, value: true)
            }
            return try await joinRemoteOnlyOpen(task)
        }
        do {
            let opened = try await openLocal(workID: workID)
            lanes[workID, default: WorkLane()].importFailure = nil
            return opened
        } catch SyncV2ApplicationError.workNotFound {
            guard runtimeIdentity != .preview else {
                throw SyncV2ApplicationError.workNotFound
            }
        }
        try Task.checkCancellation()
        guard remoteSchedulingSuspensions.isEmpty else {
            throw SyncV2Failure.accountFenceChanged
        }
        // openLocal suspends: another caller may have started the import meanwhile.
        if let task = lanes[workID, default: WorkLane()].remoteOnlyOpen {
            if opening {
                setLaneFlag(\.shouldOpenImportedWork, workID: workID, value: true)
            }
            return try await joinRemoteOnlyOpen(task)
        }
        if opening {
            setLaneFlag(\.shouldOpenImportedWork, workID: workID, value: true)
        }
        lanes[workID, default: WorkLane()].importFailure = nil
        let progress = ImportProgress()
        lanes[workID, default: WorkLane()].importProgress = progress
        let generation = historyScopeGeneration
        let timeout = remoteOnlyImportTimeout
        let task = Task {
            defer {
                setLaneFlag(\.shouldOpenImportedWork, workID: workID, value: false)
                progress.finish()
                lanes[workID, default: WorkLane()].importProgress = nil
                lanes[workID, default: WorkLane()].remoteOnlyOpen = nil
            }
            return try await ImportProgress.$current.withValue(progress) {
                try await self.performRemoteOnlyOpen(workID: workID, generation: generation, timeout: timeout)
            }
        }
        lanes[workID, default: WorkLane()].remoteOnlyOpen = task
        return try await joinRemoteOnlyOpen(task)
    }

    private func joinRemoteOnlyOpen(_ task: Task<SyncV2OpenedWork, Error>) async throws -> SyncV2OpenedWork {
        try await withTaskCancellationHandler {
            let opened = try await task.value
            try Task.checkCancellation()
            return opened
        } onCancel: {
            task.cancel()
        }
    }

    private func performRemoteOnlyOpen(workID: WorkID, generation: UInt64, timeout: Duration) async throws -> SyncV2OpenedWork {
        var stage = "remote-only-download"
        do {
            try checkRemoteOnlyScope(generation)
            let progress = ImportProgress.current ?? ImportProgress()
            let inbox = try await ImportProgress.$current.withValue(progress) {
                try await withThrowingTaskGroup(of: SyncV2RemoteInbox.self) { group in
                    group.addTask { try await self.remoteReads.downloadRemoteOnly(workID: workID) }
                    group.addTask {
                        while true {
                            let remaining = progress.remaining(untilStalledFor: timeout)
                            guard remaining > .zero else { throw SyncV2Failure.retryable(.lostResponse) }
                            try await Task.sleep(for: remaining)
                        }
                    }
                    defer { group.cancelAll() }
                    guard let inbox = try await group.next() else { throw CancellationError() }
                    return inbox
                }
            }
            try checkRemoteOnlyScope(generation)
            guard inbox.workID == workID else { throw SyncV2Failure.receiptMismatch }
            stage = "remote-only-install"
            let opened = try await kernel.installRemoteOnly(inbox)
            try checkRemoteOnlyScope(generation)
            guard opened.workID == workID, opened.document != nil else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            scheduleHistoryBackfill(workID: workID)
            setState(workID: workID, localDurability: durability(for: opened),
                     remoteProgress: .idle, result: .remoteOnlyInstalled, conflict: .clear)
            if lanes[workID, default: WorkLane()].shouldOpenImportedWork {
                progress.advance(to: .opening)
            }
            return opened
        } catch {
            if !Task.isCancelled, !(error is CancellationError), historyScopeGeneration == generation {
                lanes[workID, default: WorkLane()].importFailure = (error as? SyncV2Failure) ?? .fatal(.unexpected)
            }
            recordSyncDiagnostic(workID: workID, stage: stage, error: error)
            throw error
        }
    }

    private func checkRemoteOnlyScope(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard historyScopeGeneration == generation, remoteSchedulingSuspensions.isEmpty else {
            throw SyncV2Failure.accountFenceChanged
        }
    }

    /// The platform document gate must be held, and account/session checks
    /// repeated after this await. A joined rename may have advanced the local
    /// version since the import returned; that older result must not enter the editor.
    func isCurrentLocalVersion(_ opened: SyncV2OpenedWork) async throws -> Bool {
        try Task.checkCancellation()
        return try await kernel.currentGeneration(workID: opened.workID) == opened.generation
    }

    func library() async throws -> SyncV2LibraryProjection {
        let projection = try await libraryProvider.library()
        return SyncV2LibraryProjection(items: projection.items.map { item in
            guard let state = lanes[item.workID, default: WorkLane()].state else { return item }
            if item.accountState == .parkedDifferentAccount {
                return SyncV2LibraryItem(
                    workID: item.workID,
                    title: item.title,
                    availability: item.availability,
                    accountState: item.accountState,
                    localGeneration: item.localGeneration,
                    remoteHead: item.remoteHead,
                    remoteHeadConfirmed: item.remoteHeadConfirmed,
                    conflict: nil,
                    remoteProgress: .parkedDifferentAccount,
                    oldestUnreceivedAt: item.oldestUnreceivedAt, historyBackfillNote: item.historyBackfillNote
                )
            }
            let conflict: SyncV2ConflictProjection? = switch state.remoteProgress {
            case .readyForSafeAdoption:
                nil
            default:
                state.conflict ?? item.conflict
            }
            return SyncV2LibraryItem(
                workID: item.workID,
                title: item.title,
                availability: item.availability,
                accountState: item.accountState,
                localGeneration: item.localGeneration,
                remoteHead: item.remoteHead,
                remoteHeadConfirmed: item.remoteHeadConfirmed,
                conflict: conflict,
                remoteProgress: state.remoteProgress,
                oldestUnreceivedAt: item.oldestUnreceivedAt, historyBackfillNote: item.historyBackfillNote
            )
        })
    }

    func synchronize(workID: WorkID) async throws -> SyncV2OperationResult {
        lanes[workID, default: WorkLane()].syncDiagnostic = nil
        var diagnosticStage = "pending-adoption"
        do {
            if let adoption = try await kernel.pendingAdoption(workID: workID) {
                let state = setState(
                    workID: workID,
                    localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                    remoteProgress: .readyForSafeAdoption(inboxID: adoption.inboxID),
                    result: .adoptionPending,
                    conflict: .clear
                )
                return SyncV2OperationResult(
                    state: state,
                    typedResult: .adoptionPending
                )
            }
            diagnosticStage = "active-conflict"
            if let conflict = try await kernel.activeConflict(workID: workID) {
                let state = setState(
                    workID: workID,
                    localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                    remoteProgress: .needsChoice,
                    result: .conflictPending,
                    conflict: .set(conflict)
                )
                return SyncV2OperationResult(
                    state: state,
                    typedResult: .conflictPending
                )
            }
            diagnosticStage = "request-sync"
            try await planner.requestSynchronization(workID: workID)
            if let candidate = try await planner.automaticSyncCandidate(workID: workID),
               candidate.acknowledgedSnapshotID != nil {
                let state = setState(workID: workID,
                                     localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                                     remoteProgress: .pending, result: .queued)
                scheduleCleanRemoteCheck(workID: workID)
                return SyncV2OperationResult(state: state, typedResult: .queued)
            }
            cancelLeafPromotion(workID: workID)
            diagnosticStage = "plan-command"
            return try await synchronizePendingCommand(workID: workID)
        } catch {
            recordSyncDiagnostic(workID: workID, stage: diagnosticStage, error: error)
            throw error
        }
    }
}

private extension SyncV2Application {
    func synchronizePendingCommand(
        workID: WorkID
    ) async throws -> SyncV2OperationResult {
        let plan = try await planner.nextCommand(workID: workID)
        switch plan {
        case .idle:
            let state = setState(
                workID: workID,
                localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                remoteProgress: .noChanges,
                result: .noChanges
            )
            return SyncV2OperationResult(state: state, typedResult: .noChanges)
        case let .blocked(failure):
            recordSyncDiagnostic(workID: workID, stage: "plan-blocked", error: failure)
            let state = record(failure: failure, workID: workID)
            return SyncV2OperationResult(
                state: state,
                typedResult: .failure(failure)
            )
        case .command, .upload:
            let state = setState(
                workID: workID,
                localDurability: lanes[workID, default: WorkLane()].state?.localDurability ?? .unsaved,
                remoteProgress: .pending,
                result: .queued
            )
            scheduleWorker(for: workID)
            return SyncV2OperationResult(state: state, typedResult: .queued)
        }
    }
}
