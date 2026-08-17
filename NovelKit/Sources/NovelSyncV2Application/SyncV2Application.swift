import Foundation
import NovelCore
import NovelSyncV2

public struct SyncV2OperationResult: Sendable {
    public let state: SyncUIState
    public let typedResult: SyncV2TypedResult
    /// A local work prepared as part of the operation (currently keep-both).
    /// The caller can switch its editor without another remote round-trip.
    public let openedWork: SyncV2OpenedWork?

    public init(
        state: SyncUIState,
        typedResult: SyncV2TypedResult,
        openedWork: SyncV2OpenedWork? = nil
    ) {
        self.state = state
        self.typedResult = typedResult
        self.openedWork = openedWork
    }
}

public actor SyncV2Application {
    let kernel: any SyncV2LocalKernel
    let planner: any SyncV2CommandPlanner
    let remote: any SyncV2RemoteClient
    let gate: any SyncV2DocumentGate
    let libraryProvider: any SyncV2LibraryProvider
    let runtimeIdentity: SyncV2RuntimeComposition.Identity
    var workerTasks: [WorkID: Task<Void, Never>] = [:]
    var wakeEpochs: [WorkID: UInt64] = [:]
    var states: [WorkID: SyncUIState] = [:]
    var sessions: [WorkID: DocumentSessionToken] = [:]

    package init(
        mode: RuntimeMode,
        composition: SyncV2RuntimeComposition
    ) throws {
        let valid = switch (mode, composition.identity) {
        case (.production, .production), (.test, .test), (.preview, .preview):
            true
        default:
            false
        }
        guard valid else { throw SyncV2ApplicationError.invalidRuntimeMode }
        kernel = composition.kernel
        planner = composition.planner
        remote = composition.remote
        gate = composition.gate
        libraryProvider = composition.library
        runtimeIdentity = composition.identity
    }

    public func checkpoint(
        workID: WorkID,
        document: NovelDocument,
        reason: SyncV2CheckpointReason,
        documentCreatedAt: Date,
        attachments: [SyncAttachment] = [],
        resources: [PortableResource]? = nil
    ) async throws -> SyncV2OperationResult {
        guard runtimeIdentity != .preview else {
            throw SyncV2ApplicationError.previewReadOnly
        }
        let expectedGeneration = try await checkpointGeneration(workID: workID)
        setState(
            workID: workID,
            localDurability: .saving,
            remoteProgress: states[workID]?.remoteProgress ?? .idle,
            result: .checkpointed
        )
        do {
            let local = try await kernel.checkpoint(
                SyncV2CheckpointCapture(
                    workID: workID,
                    document: document,
                    documentCreatedAt: documentCreatedAt,
                    expectedGeneration: expectedGeneration,
                    reason: reason,
                    attachments: attachments,
                    resources: resources
                )
            )
            return try await finishCheckpoint(local, workID: workID)
        } catch {
            setState(
                workID: workID,
                localDurability: .failed,
                remoteProgress: states[workID]?.remoteProgress ?? .idle,
                result: .failure(.fatal(.invalidLocalState)),
                failure: .fatal(.invalidLocalState)
            )
            throw error
        }
    }
}

extension SyncV2Application {
    func checkpointGeneration(workID: WorkID) async throws -> Int64 {
        do {
            return try await kernel.open(workID: workID).generation
        } catch SyncV2ApplicationError.workNotFound {
            return 0
        }
    }

    func finishCheckpoint(
        _ local: SyncV2LocalCheckpoint,
        workID: WorkID
    ) async throws -> SyncV2OperationResult {
        let result: SyncV2TypedResult = local.noChanges
            ? .noChanges : .checkpointed
        let hasPending = local.intentID != nil
        let durableConflict = try await kernel.activeConflict(workID: workID) != nil
        let hasConflict = states[workID]?.conflict != nil || durableConflict
        let state = setState(
            workID: workID,
            localDurability: .saved(
                generation: local.generation,
                snapshotID: local.snapshotID
            ),
            remoteProgress: hasConflict ? .needsChoice : (hasPending ? .pending : .noChanges),
            result: result
        )
        if hasPending, !hasConflict {
            scheduleWorker(for: workID)
        }
        return SyncV2OperationResult(state: state, typedResult: result)
    }

    func recordOpened(_ opened: SyncV2OpenedWork) {
        setState(
            workID: opened.workID,
            localDurability: durability(for: opened),
            remoteProgress: states[opened.workID]?.remoteProgress ?? .idle,
            result: .sent
        )
    }

    func durability(for opened: SyncV2OpenedWork) -> SyncV2LocalDurability {
        guard let snapshotID = opened.snapshotID else { return .unsaved }
        return .saved(generation: opened.generation, snapshotID: snapshotID)
    }

    @discardableResult
    func setState(
        workID: WorkID,
        localDurability: SyncV2LocalDurability,
        remoteProgress: SyncV2RemoteProgress,
        result: SyncV2TypedResult,
        conflict: SyncV2ConflictUpdate = .retain,
        failure: SyncV2Failure? = nil
    ) -> SyncUIState {
        let projectedConflict: SyncV2ConflictProjection? = switch conflict {
        case .retain: states[workID]?.conflict
        case let .set(value): value
        case .clear: nil
        }
        let state = SyncUIState(
            workID: workID,
            localDurability: localDurability,
            remoteProgress: remoteProgress,
            conflict: projectedConflict,
            lastTypedResult: result,
            lastFailure: failure
        )
        states[workID] = state
        return state
    }
}
