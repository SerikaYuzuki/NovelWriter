import Foundation
import NovelSyncV2

extension SyncV2Application {
    /// Wake every durable outbox lane.  It is safe to call repeatedly from
    /// launch, foreground, and connectivity callbacks; per-work single flight
    /// keeps command bytes and operation IDs stable.
    public func resumePending() async throws {
        guard runtimeIdentity != .preview else { return }
        for workID in try await planner.pendingWorkIDs() {
            scheduleWorker(for: workID)
        }
    }

    func scheduleWorker(for workID: WorkID) {
        wakeEpochs[workID, default: 0] &+= 1
        guard workerTasks[workID] == nil, runtimeIdentity != .preview else {
            return
        }
        workerTasks[workID] = Task { [weak self] in
            guard let self else { return }
            await runWorker(for: workID)
        }
    }

    func runWorker(for workID: WorkID) async {
        while !Task.isCancelled {
            let observedWake = wakeEpochs[workID, default: 0]
            do {
                let plan = try await planner.nextCommand(workID: workID)
                switch plan {
                case .idle:
                    if finishWorkerIfUnchanged(
                        workID: workID,
                        observedWake: observedWake
                    ) {
                        return
                    }
                case let .blocked(failure):
                    record(failure: failure, workID: workID)
                    if finishWorkerIfUnchanged(
                        workID: workID,
                        observedWake: observedWake
                    ) {
                        return
                    }
                case let .command(command):
                    try await execute(
                        .command(SyncV2SealedRemoteCommand(command: command)),
                        workID: workID
                    )
                    if ["resolveServer", "resolveDevice", "cloneWork"].contains(command.commandKind) {
                        workerTasks[workID] = nil
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
                    try await execute(.upload(upload), workID: workID)
                }
            } catch {
                let failure = (error as? SyncV2Failure) ?? .fatal(.unexpected)
                record(failure: failure, workID: workID)
                if finishWorkerIfUnchanged(
                    workID: workID,
                    observedWake: observedWake
                ) {
                    return
                }
            }
        }
        workerTasks[workID] = nil
    }

    private func execute(
        _ proposed: SyncV2RemoteOperation,
        workID: WorkID
    ) async throws {
        let sending = try await planner.markSending(proposed, workID: workID)
        setState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: .syncing(operationID: operationID(sending)),
            result: .queued
        )
        do {
            let execution = try await remote.execute(sending)
            try await accept(execution, for: sending, workID: workID)
        } catch {
            let failure = (error as? SyncV2Failure) ?? .fatal(.unexpected)
            try? await planner.recordFailure(
                operation: sending,
                workID: workID,
                disposition: disposition(for: failure)
            )
            record(failure: failure, workID: workID)
            throw failure
        }
    }

    private func accept(
        _ execution: SyncV2RemoteExecution,
        for operation: SyncV2RemoteOperation,
        workID: WorkID
    ) async throws {
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
                try validateInbox(
                    inbox,
                    receipt: receipt,
                    command: planned.command,
                    workID: workID
                )
                try await kernel.stageRemote(inbox)
                try await kernel.verifyRemote(
                    inboxID: inbox.inboxID,
                    workID: inbox.workID
                )
                if receipt.result == .conflictPending, let conflict = receipt.conflict {
                    try await kernel.recordConflict(
                        conflict,
                        workID: inbox.workID,
                        inboxID: inbox.inboxID
                    )
                }
            }
            try await planner.acknowledgeCommand(
                receipt,
                command: planned.command,
                verifiedInboxID: inbox?.inboxID ?? receipt.verifiedInboxID
            )
            try await project(receipt, command: planned, workID: workID)
        case let (.upload(planned), .upload(completion)):
            guard completion.transferID == planned.transferID,
                  completion.uploadID == planned.uploadID,
                  completion.objectID == planned.objectID,
                  completion.acknowledgedByteCount == planned.exactBytes.count else {
                throw SyncV2Failure.receiptMismatch
            }
            try await planner.acknowledgeUpload(completion)
            setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .pending,
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
                conflict = .retain
            } else {
                result = .sent
                progress = .idle
                conflict = command.kind.isConflictResolution ? .clear : .retain
            }
        case .noChanges:
            if command.kind == .resolveServer {
                guard let adoption = try await kernel.pendingAdoption(
                    workID: workID
                ) else { throw SyncV2Failure.receiptMismatch }
                result = .adoptionPending
                progress = .readyForSafeAdoption(inboxID: adoption.inboxID)
                conflict = .retain
            } else {
                result = .noChanges
                progress = .noChanges
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
                conflict = .retain
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

    private func finishWorkerIfUnchanged(
        workID: WorkID,
        observedWake: UInt64
    ) -> Bool {
        guard wakeEpochs[workID, default: 0] == observedWake else {
            return false
        }
        workerTasks[workID] = nil
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
