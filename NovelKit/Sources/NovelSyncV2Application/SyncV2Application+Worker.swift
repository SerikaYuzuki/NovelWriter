import Foundation
import NovelSyncV2

extension SyncV2Application {
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
                  receipt.predicates.allVerified else {
                throw SyncV2Failure.receiptMismatch
            }
            if let inbox {
                try await kernel.stageRemote(inbox)
                try await kernel.verifyRemote(
                    inboxID: inbox.inboxID,
                    workID: inbox.workID
                )
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
            result = .conflictPending
            progress = .needsChoice
            conflict = .set(candidate)
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
