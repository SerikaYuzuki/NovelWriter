import Foundation
import NovelSyncV2

extension SyncV2Application {
    /// Wake every durable outbox lane.  It is safe to call repeatedly from
    /// launch, foreground, and connectivity callbacks; per-work single flight
    /// keeps command bytes and operation IDs stable.
    public func resumePending() async throws {
        guard runtimeIdentity != .preview, remoteSchedulingSuspensions.isEmpty else { return }
        try await resumeHistoryBackfills()
        for deletion in try await kernel.workDeletions() where !deletion.completed {
            Task { try? await self.deleteWork(workID: deletion.workID) }
        }
        for workID in try await planner.pendingWorkIDs() {
            if try await !kernel.hasUnpromotedLeaf(workID: workID) {
                cancelLeafPromotion(workID: workID)
            }
            scheduleWorker(for: workID)
        }
    }

    /// Invalidates the worker slot before cancelling the task.  Cancellation
    /// is advisory for a remote implementation, so owner invalidation is the
    /// actual late-completion boundary.
    func cancelWorker(for workID: WorkID) {
        cancelRetry(for: workID)
        retryAttempts[workID] = nil
        workerOwners[workID] = nil
        workerTasks[workID]?.cancel()
        workerTasks[workID] = nil
        wakeEpochs[workID, default: 0] &+= 1
    }

    func scheduleWorker(for workID: WorkID) {
        cancelRetry(for: workID)
        wakeEpochs[workID, default: 0] &+= 1
        guard !deletingWorkIDs.contains(workID), workerTasks[workID] == nil,
              runtimeIdentity != .preview,
              remoteSchedulingSuspensions.isEmpty else {
            return
        }
        let owner = UUID()
        workerOwners[workID] = owner
        workerTasks[workID] = Task { [weak self] in
            guard let self else { return }
            await runWorker(for: workID, owner: owner)
        }
    }

    func runWorker(for workID: WorkID, owner: UUID) async {
        while !Task.isCancelled {
            guard isCurrentWorker(workID: workID, owner: owner) else { return }
            let observedWake = wakeEpochs[workID, default: 0]
            syncDiagnostics[workID] = nil
            do {
                let plan = try await planner.nextCommand(workID: workID)
                guard isCurrentWorker(workID: workID, owner: owner) else { return }
                switch plan {
                case .idle:
                    let hasLeaf = try await kernel.hasUnpromotedLeaf(workID: workID)
                    if finishWorkerIfUnchanged(
                        workID: workID,
                        owner: owner,
                        observedWake: observedWake
                    ) {
                        projectCompletedWorker(workID: workID, hasLeaf: hasLeaf)
                        return
                    }
                case let .blocked(failure):
                    recordSyncDiagnostic(workID: workID, stage: "worker/plan-blocked", error: failure)
                    guard isCurrentWorker(workID: workID, owner: owner) else { return }
                    record(failure: failure, workID: workID)
                    if finishWorkerIfUnchanged(
                        workID: workID,
                        owner: owner,
                        observedWake: observedWake
                    ) {
                        return
                    }
                case let .command(command):
                    let completed = try await execute(
                        .command(SyncV2SealedRemoteCommand(command: command)),
                        workID: workID,
                        owner: owner
                    )
                    guard completed else { return }
                    guard isCurrentWorker(workID: workID, owner: owner) else { return }
                    if ["resolveServer", "resolveDevice", "cloneWork"].contains(command.commandKind) {
                        guard finishCurrentWorker(workID: workID, owner: owner) else {
                            return
                        }
                        if command.commandKind != "resolveServer" {
                            scheduleWorker(for: workID)
                        } else if wakeEpochs[workID, default: 0] != observedWake {
                            // Safe adoption can arrive while this resolution
                            // task is handing off. Preserve that wake after
                            // the task releases its single-flight slot.
                            scheduleWorker(for: workID)
                        }
                        return
                    }
                case let .upload(upload):
                    guard try await execute(.upload(upload), workID: workID, owner: owner) else {
                        return
                    }
                }
            } catch {
                guard isCurrentWorker(workID: workID, owner: owner) else { return }
                recordSyncDiagnosticIfAbsent(workID: workID, stage: "worker/plan-command", error: error)
                let failure = (error as? SyncV2Failure) ?? .fatal(.unexpected)
                record(failure: failure, workID: workID)
                if finishWorkerIfUnchanged(
                    workID: workID,
                    owner: owner,
                    observedWake: observedWake
                ) {
                    return
                }
            }
        }
        _ = finishCurrentWorker(workID: workID, owner: owner)
    }

    private func execute(
        _ proposed: SyncV2RemoteOperation,
        workID: WorkID,
        owner: UUID
    ) async throws -> Bool {
        guard isCurrentWorker(workID: workID, owner: owner) else { return false }
        let sending = try await planner.markSending(proposed, workID: workID)
        guard isCurrentWorker(workID: workID, owner: owner) else { return false }
        setState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: .syncing(operationID: operationID(sending)),
            result: .queued
        )
        var diagnosticStage = "worker/remote"
        if case let .command(command) = sending {
            diagnosticStage += "/" + command.command.commandKind
        }
        do {
            let execution = try await remote.execute(sending)
            diagnosticStage = "worker/accept"
            guard isCurrentWorker(workID: workID, owner: owner) else { return false }
            try await accept(execution, for: sending, workID: workID, owner: owner)
            guard isCurrentWorker(workID: workID, owner: owner) else { return false }
            return true
        } catch {
            if !isCurrentWorker(workID: workID, owner: owner) {
                return false
            }
            recordSyncDiagnostic(workID: workID, stage: diagnosticStage, error: error)
            let failure = (error as? SyncV2Failure) ?? .fatal(.unexpected)
            let failureDisposition: SyncV2CommandFailureDisposition = if case .upload = sending, case let .fatal(reason) = failure {
                .rejectUpload(reason)
            } else if case .command = sending, case let .fatal(reason) = failure {
                .rejectCommand(reason)
            } else {
                disposition(for: failure)
            }
            try await planner.recordFailure(
                operation: sending,
                workID: workID,
                disposition: failureDisposition
            )
            guard isCurrentWorker(workID: workID, owner: owner) else { return false }
            if failure == .retryable(.publishLineageRejected) {
                return true
            }
            record(failure: failure, workID: workID)
            throw failure
        }
    }

    private func accept(
        _ execution: SyncV2RemoteExecution,
        for operation: SyncV2RemoteOperation,
        workID: WorkID,
        owner: UUID
    ) async throws {
        guard isCurrentWorker(workID: workID, owner: owner) else { return }
        switch (operation, execution) {
        case let (.command(planned), .command(receipt, inbox)):
            guard receipt.commandID == planned.command.commandId,
                  receipt.requestDigest == planned.command.requestDigest,
                  receipt.predicates.allVerified,
                  try commandWorkID(planned.command) == workID else {
                throw SyncV2Failure.receiptMismatch
            }
            guard receipt.result != .conflictPending || inbox != nil else {
                throw SyncV2Failure.receiptMismatch
            }
            if let inbox {
                guard isCurrentWorker(workID: workID, owner: owner) else { return }
                try validateInbox(
                    inbox,
                    receipt: receipt,
                    command: planned.command,
                    workID: workID
                )
                try await kernel.stageRemote(inbox)
                guard isCurrentWorker(workID: workID, owner: owner) else { return }
                try await kernel.verifyRemote(
                    inboxID: inbox.inboxID,
                    workID: inbox.workID
                )
                guard isCurrentWorker(workID: workID, owner: owner) else { return }
                if receipt.result == .conflictPending, let conflict = receipt.conflict {
                    try await kernel.recordConflict(
                        conflict,
                        workID: inbox.workID,
                        inboxID: inbox.inboxID
                    )
                    guard isCurrentWorker(workID: workID, owner: owner) else { return }
                }
            }
            guard isCurrentWorker(workID: workID, owner: owner) else { return }
            try await planner.acknowledgeCommand(
                receipt,
                command: planned.command,
                verifiedInboxID: inbox?.inboxID ?? receipt.verifiedInboxID
            )
            guard isCurrentWorker(workID: workID, owner: owner) else { return }
            try await project(receipt, command: planned, workID: workID)
            guard isCurrentWorker(workID: workID, owner: owner) else { return }
        case let (.upload(planned), .upload(completion)):
            guard completion.transferID == planned.transferID,
                  completion.uploadID == planned.uploadID,
                  completion.objectID == planned.objectID,
                  completion.acknowledgedByteCount == planned.exactBytes.count else {
                throw SyncV2Failure.receiptMismatch
            }
            guard isCurrentWorker(workID: workID, owner: owner) else { return }
            try await planner.acknowledgeUpload(completion)
            guard isCurrentWorker(workID: workID, owner: owner) else { return }
            setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .syncing(operationID: planned.transferID),
                result: .queued
            )
        default:
            throw SyncV2Failure.receiptMismatch
        }
    }

    private func commandWorkID(_ command: SealedCommand) throws -> WorkID {
        guard let object = try JSONSerialization.jsonObject(with: command.payloadBytes) as? [String: Any],
              let raw = (object["workId"] as? String) ?? (object["sourceWorkId"] as? String) else {
            throw SyncV2Failure.receiptMismatch
        }
        return try WorkID(uuidString: raw)
    }

    private func validateInbox(
        _ inbox: SyncV2RemoteInbox,
        receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        workID: WorkID
    ) throws {
        guard inbox.workID == workID,
              inbox.headSnapshotID == inbox.expectedRemoteHead.snapshotID,
              receipt.remoteHead == inbox.expectedRemoteHead,
              inbox.expectedLocalGeneration == command.sourceGeneration,
              inbox.expectedCurrentSnapshotID == command.sourceSnapshotId else {
            throw SyncV2Failure.receiptMismatch
        }
        if let conflict = receipt.conflict {
            let expectedBase = try expectedRemoteHeadSnapshotID(command)
            guard receipt.result == .conflictPending,
                  conflict.localSnapshotID == command.sourceSnapshotId,
                  conflict.sourceGeneration == command.sourceGeneration,
                  conflict.remoteSnapshotID == inbox.headSnapshotID,
                  conflict.baseSnapshotID == expectedBase else {
                throw SyncV2Failure.receiptMismatch
            }
        } else {
            guard receipt.result != .conflictPending else {
                throw SyncV2Failure.receiptMismatch
            }
        }
    }

    private func expectedRemoteHeadSnapshotID(_ command: SealedCommand) throws -> SnapshotID? {
        guard let payload = try JSONSerialization.jsonObject(with: command.payloadBytes) as? [String: Any],
              let raw = payload["expectedRemoteHead"] else {
            throw SyncV2Failure.receiptMismatch
        }
        if raw is NSNull {
            return nil
        }
        guard let head = raw as? [String: Any],
              Set(head.keys) == ["generation", "snapshotId"],
              head["generation"] is NSNumber,
              let snapshot = head["snapshotId"] as? String else {
            throw SyncV2Failure.receiptMismatch
        }
        return try SnapshotID(rawValue: snapshot)
    }

    private func project(
        _ receipt: SyncV2ReceiptReadback,
        command: SyncV2SealedRemoteCommand,
        workID: WorkID
    ) async throws {
        let result: SyncV2TypedResult
        let progress: SyncV2RemoteProgress
        let conflict: SyncV2ConflictUpdate
        switch receipt.result {
        case .applied:
            if command.kind == .resolveServer {
                guard let adoption = try await kernel.pendingAdoption(
                    workID: workID
                ) else { throw SyncV2Failure.receiptMismatch }
                result = .adoptionPending
                progress = .readyForSafeAdoption(inboxID: adoption.inboxID)
                conflict = .clear
            } else {
                result = .sent
                progress = .syncing(operationID: command.command.commandId)
                conflict = command.kind.isConflictResolution ? .clear : .retain
            }
        case .noChanges:
            if command.kind == .publish, let adoption = try await kernel.pendingAdoption(workID: workID) {
                result = .adoptionPending
                progress = .readyForSafeAdoption(inboxID: adoption.inboxID)
                conflict = .clear
            } else if command.kind == .resolveServer {
                guard let adoption = try await kernel.pendingAdoption(
                    workID: workID
                ) else { throw SyncV2Failure.receiptMismatch }
                result = .adoptionPending
                progress = .readyForSafeAdoption(inboxID: adoption.inboxID)
                conflict = .clear
            } else {
                result = .noChanges
                progress = .syncing(operationID: command.command.commandId)
                conflict = command.kind.isConflictResolution ? .clear : .retain
            }
        case .conflictPending:
            guard let candidate = receipt.conflict else {
                throw SyncV2Failure.receiptMismatch
            }
            // A conflict receipt can be projected after the resolution ACK
            // when the two worker actor hops interleave.  Once the durable
            // server-adoption marker exists, it is authoritative and must
            // not regress the UI back to the choice screen.
            if let adoption = try await kernel.pendingAdoption(workID: workID) {
                result = .adoptionPending
                progress = .readyForSafeAdoption(inboxID: adoption.inboxID)
                conflict = .clear
            } else {
                result = .conflictPending
                progress = .needsChoice
                conflict = .set(candidate)
            }
        }
        setState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: progress,
            result: result,
            conflict: conflict
        )
    }

    /// A receipt completes one operation. Only a stable idle read completes the lane.
    private func projectCompletedWorker(workID: WorkID, hasLeaf: Bool) {
        cancelRetry(for: workID)
        retryAttempts[workID] = nil
        guard let state = states[workID], case .syncing = state.remoteProgress else { return }
        setState(workID: workID, localDurability: state.localDurability,
                 remoteProgress: hasLeaf ? .pending : .noChanges, result: .noChanges)
    }

    private func finishWorkerIfUnchanged(
        workID: WorkID,
        owner: UUID,
        observedWake: UInt64
    ) -> Bool {
        guard isCurrentWorker(workID: workID, owner: owner),
              !Task.isCancelled,
              wakeEpochs[workID, default: 0] == observedWake else {
            return false
        }
        return finishCurrentWorker(workID: workID, owner: owner)
    }

    private func isCurrentWorker(workID: WorkID, owner: UUID) -> Bool {
        workerOwners[workID] == owner &&
            workerTasks[workID] != nil &&
            !Task.isCancelled
    }

    @discardableResult
    private func finishCurrentWorker(workID: WorkID, owner: UUID) -> Bool {
        guard workerOwners[workID] == owner else { return false }
        workerOwners[workID] = nil
        workerTasks[workID] = nil
        scheduleRetryIfNeeded(for: workID)
        return true
    }

    private func operationID(_ operation: SyncV2RemoteOperation) -> UUID {
        switch operation {
        case let .command(command): command.command.commandId
        case let .upload(upload): upload.transferID
        }
    }

    private func disposition(
        for failure: SyncV2Failure
    ) -> SyncV2CommandFailureDisposition {
        switch failure {
        case .retryable(.publishLineageRejected):
            .replanRejectedPublish
        case .retryable(.uploadExpired):
            // The server rejected this capability before committing a receipt.
            // Retire the sealed command so the next attempt can prepare anew.
            .quarantine
        case .offline, .authenticationRequired, .retryable:
            .requeue
        case .accountFenceChanged, .quarantined, .fatal, .receiptMismatch:
            .quarantine
        }
    }

    @discardableResult
    func record(failure: SyncV2Failure, workID: WorkID) -> SyncUIState {
        let progress: SyncV2RemoteProgress = switch failure {
        case .offline: .offline
        case .authenticationRequired: .authenticationRequired
        case .accountFenceChanged: .fenceChanged
        case let .quarantined(reason):
            reason == .differentAccount
                ? .parkedDifferentAccount : .quarantined(reason)
        case let .retryable(reason): .retryable(reason)
        case let .fatal(reason): .failed(reason)
        case .receiptMismatch: .receiptMismatch
        }
        return setState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: progress,
            result: .failure(failure),
            failure: failure
        )
    }
}

private extension SyncV2RemoteOperationKind {
    var isConflictResolution: Bool {
        switch self {
        case .resolveDevice, .resolveServer, .cloneWork: true
        default: false
        }
    }
}
