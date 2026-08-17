import Foundation
import NovelCore
import NovelSyncV2

public struct SyncV2OperationResult: Sendable {
    public let state: SyncUIState
    public let typedResult: SyncV2TypedResult

    public init(state: SyncUIState, typedResult: SyncV2TypedResult) {
        self.state = state
        self.typedResult = typedResult
    }
}

public actor SyncV2Application {
    private let kernel: any SyncV2LocalKernel
    private let transport: any SyncV2Transport
    private var workerTasks: [WorkID: Task<Void, Never>] = [:]
    private var states: [WorkID: SyncUIState] = [:]
    private var sessions: [WorkID: UUID] = [:]

    public init(mode: RuntimeMode) throws {
        switch mode {
        case let .production(dependencies):
            kernel = dependencies.kernel
            transport = dependencies.transport
        case let .test(dependencies):
            kernel = dependencies.kernel
            transport = dependencies.transport
        case .preview:
            kernel = InMemorySyncV2Kernel()
            transport = PreviewTransport()
        }
    }

    public init(
        kernel: any SyncV2LocalKernel,
        transport: any SyncV2Transport
    ) {
        self.kernel = kernel
        self.transport = transport
    }

    public func checkpoint(
        workID: WorkID,
        document: NovelDocument,
        reason: SyncV2CheckpointReason,
        documentCreatedAt: Date = Date(timeIntervalSince1970: 0),
        attachments: [SyncAttachment] = []
    ) async throws -> SyncV2OperationResult {
        setState(
            workID: workID,
            localDurability: .saving,
            remoteProgress: states[workID]?.remoteProgress ?? .idle,
            result: .checkpointed
        )
        do {
            let current = try? await kernel.open(workID: workID)
            let parents = current?.snapshotID.map { [$0] } ?? []
            let encoded = try SnapshotCodec.encode(
                SnapshotModel(
                    workId: workID,
                    document: document,
                    documentCreatedAt: documentCreatedAt,
                    attachments: attachments
                ),
                parents: parents
            )
            let local = try await kernel.checkpoint(
                SyncV2CheckpointCapture(
                    workID: workID,
                    encoded: encoded,
                    reason: reason
                )
            )
            let result: SyncV2TypedResult = local.noChanges ? .noChanges : .checkpointed
            let state = setState(
                workID: workID,
                localDurability: .saved(
                    generation: local.generation,
                    snapshotID: local.snapshotID
                ),
                remoteProgress: .idle,
                result: result
            )
            scheduleWorker(for: workID)
            return SyncV2OperationResult(state: state, typedResult: result)
        } catch {
            let state = setState(
                workID: workID,
                localDurability: .failed,
                remoteProgress: .failed,
                result: .failed
            )
            _ = state
            throw error
        }
    }

    public func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        let opened = try await kernel.open(workID: workID)
        let durability: SyncV2LocalDurability = if let snapshotID = opened.snapshotID {
            .saved(generation: opened.generation, snapshotID: snapshotID)
        } else {
            .unsaved
        }
        setState(
            workID: workID,
            localDurability: durability,
            remoteProgress: states[workID]?.remoteProgress ?? .idle,
            result: .sent
        )
        // Opening is local-only. Worker scheduling is deliberately detached
        // from the operation and is never awaited by the caller.
        scheduleWorker(for: workID)
        return opened
    }

    public func synchronize(workID: WorkID) async throws -> SyncV2OperationResult {
        let pending = try await kernel.pendingCommands(workID: workID)
        guard !pending.isEmpty else {
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
            remoteProgress: .syncing(commandID: pending[0].commandId),
            result: .queued
        )
        scheduleWorker(for: workID)
        return SyncV2OperationResult(state: state, typedResult: .queued)
    }

    public func resolveConflict(
        workID: WorkID,
        action: SyncV2ConflictAction
    ) async throws -> SyncV2OperationResult {
        guard action.workID == workID else { throw SyncV2ApplicationError.staleConflictAction }
        do {
            let command = try await kernel.prepareConflict(action)
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .syncing(commandID: command.commandId),
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
            return SyncV2OperationResult(state: state, typedResult: .staleConflictAction)
        }
    }

    public func restore(
        workID: WorkID,
        snapshotID: SnapshotID
    ) async throws -> SyncV2OperationResult {
        let command = try await kernel.prepareRestore(
            SyncV2RestoreRequest(workID: workID, snapshotID: snapshotID)
        )
        guard let command else {
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
            remoteProgress: .syncing(commandID: command.commandId),
            result: .restored
        )
        scheduleWorker(for: workID)
        return SyncV2OperationResult(state: state, typedResult: .restored)
    }

    public func beginSession(workID: WorkID) -> UUID {
        let token = UUID()
        sessions[workID] = token
        return token
    }

    public func applyStagedRemote(
        at boundary: SafeAdoptionBoundary
    ) async throws -> SyncV2OpenedWork {
        guard sessions[boundary.workID] == boundary.sessionToken,
              boundary.expectedGeneration >= 0,
              boundary.imeActive == false,
              boundary.hasUnsavedChanges == false,
              boundary.hasPendingIntent == false,
              boundary.documentGateProof != UUID() else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        guard let state = states[boundary.workID] else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        guard case let .saved(generation, snapshotID) = state.localDurability,
              generation == boundary.expectedGeneration,
              snapshotID == boundary.expectedSnapshotID else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        return try await kernel.applyStagedRemote(boundary)
    }

    public func uiState(workID: WorkID) -> SyncUIState? {
        states[workID]
    }

    private func scheduleWorker(for workID: WorkID) {
        guard workerTasks[workID] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await runWorker(for: workID)
        }
        workerTasks[workID] = task
    }

    private func runWorker(for workID: WorkID) async {
        defer { workerTasks[workID] = nil }
        while !Task.isCancelled {
            guard let command = try? await kernel.pendingCommands(workID: workID),
                  let pending = command.first else {
                return
            }
            do {
                let sealed = try await kernel.markSending(
                    commandID: pending.commandId,
                    workID: workID
                )
                setState(
                    workID: workID,
                    localDurability: states[workID]?.localDurability ?? .unsaved,
                    remoteProgress: .syncing(commandID: sealed.commandId),
                    result: .queued
                )
                let response = try await transport.send(
                    SyncV2TransportRequest(
                        commandID: sealed.commandId,
                        canonicalBytes: sealed.canonicalBytes,
                        requestDigest: sealed.requestDigest
                    )
                )
                if let remoteInbox = response.remoteInbox {
                    try await kernel.stageRemote(remoteInbox)
                    try await kernel.verifyRemote(
                        inboxID: remoteInbox.inboxID,
                        workID: remoteInbox.workID
                    )
                }
                guard let receipt = response.receipt else {
                    throw SyncV2ApplicationError.missingReceipt
                }
                guard receipt.commandID == sealed.commandId,
                      receipt.requestDigest == sealed.requestDigest,
                      receipt.predicates.allVerified else {
                    throw SyncV2ApplicationError.receiptMismatch
                }
                try await kernel.acknowledge(
                    receipt,
                    command: sealed,
                    verifiedInboxID: response.remoteInbox?.inboxID ?? receipt.verifiedInboxID
                )
                let result: SyncV2TypedResult = switch receipt.result {
                case .noChanges: .noChanges
                case .applied: .sent
                case .conflictPending: .conflictPending
                }
                let progress: SyncV2RemoteProgress = switch receipt.result {
                case .conflictPending: .needsChoice
                case .noChanges: .noChanges
                case .applied: .idle
                }
                setState(
                    workID: workID,
                    localDurability: states[workID]?.localDurability ?? .unsaved,
                    remoteProgress: progress,
                    result: result,
                    conflict: receipt.conflict
                )
            } catch {
                _ = try? await kernel.requeue(commandID: pending.commandId, workID: workID)
                setState(
                    workID: workID,
                    localDurability: states[workID]?.localDurability ?? .unsaved,
                    remoteProgress: .offline,
                    result: .offline
                )
                return
            }
        }
    }

    @discardableResult
    private func setState(
        workID: WorkID,
        localDurability: SyncV2LocalDurability,
        remoteProgress: SyncV2RemoteProgress,
        result: SyncV2TypedResult,
        conflict: SyncV2ConflictProjection? = nil
    ) -> SyncUIState {
        let state = SyncUIState(
            workID: workID,
            localDurability: localDurability,
            remoteProgress: remoteProgress,
            conflict: conflict ?? states[workID]?.conflict,
            lastTypedResult: result
        )
        states[workID] = state
        return state
    }
}

private actor PreviewTransport: SyncV2Transport {
    func send(_ request: SyncV2TransportRequest) async throws -> SyncV2TransportResponse {
        _ = request
        throw SyncV2ApplicationError.previewReadOnly
    }
}
