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
    /// Identity of the currently installed worker for each Work.  A cancelled
    /// task can still resume after a non-cooperative remote await, so a task
    /// must never use the dictionary slot or clear a newer worker merely
    /// because it has the same WorkID.
    var workerOwners: [WorkID: UUID] = [:]
    var wakeEpochs: [WorkID: UInt64] = [:]
    var states: [WorkID: SyncUIState] = [:]
    var sessions: [WorkID: DocumentSessionToken] = [:]
    var remoteSchedulingSuspensions: Set<UUID> = []
    var activeAccountTransitionSuspensions: Set<UUID> = []
    /// Monotonic process-local generation for merged history cursors. A
    /// cursor is a continuation of both the account/fence scope and this
    /// application session; auth transitions invalidate it before any later
    /// page can append stale rows.
    var historyScopeGeneration: UInt64 = 0

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

    /// Parks a Work's current account lane before the auth session changes.
    /// This is deliberately local-only; no remote worker is resumed here.
    public func parkAccountScope(
        workID: WorkID,
        binding: SyncV2AccountScopeBinding
    ) async throws {
        guard runtimeIdentity != .preview else {
            throw SyncV2ApplicationError.previewReadOnly
        }
        try await kernel.parkAccountScope(workID: workID, binding: binding)
        await planner.invalidateCaches(for: [workID])
        historyScopeGeneration &+= 1
        cancelWorker(for: workID)
        states[workID] = SyncUIState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: .idle,
            conflict: nil,
            lastTypedResult: .checkpointed
        )
    }

    /// Quarantine the old fence and bind the same account to a new fence.
    /// Workers remain stopped until the new scope performs its normal
    /// bootstrap/replan path.
    public func rebindAccountScope(
        workID: WorkID,
        from old: SyncV2AccountScopeBinding,
        to new: SyncV2AccountScopeBinding
    ) async throws {
        guard runtimeIdentity != .preview else {
            throw SyncV2ApplicationError.previewReadOnly
        }
        try await kernel.rebindAccountScope(workID: workID, from: old, to: new)
        await planner.invalidateCaches(for: [workID])
        historyScopeGeneration &+= 1
        cancelWorker(for: workID)
        states[workID] = SyncUIState(
            workID: workID,
            localDurability: states[workID]?.localDurability ?? .unsaved,
            remoteProgress: .idle,
            conflict: nil,
            lastTypedResult: .checkpointed
        )
    }

    /// Performs the database-wide auth transition before any new scope can be
    /// scheduled. The store owns the transaction; this actor only invalidates
    /// every in-flight worker after the durable transition succeeds.
    public func transitionAccountScopes(
        from old: SyncV2AccountScopeBinding?,
        to new: SyncV2AccountScopeBinding?,
        suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken
    ) async throws {
        guard runtimeIdentity != .preview else {
            throw SyncV2ApplicationError.previewReadOnly
        }
        guard remoteSchedulingSuspensions.contains(suspensionToken.rawValue),
              activeAccountTransitionSuspensions.isEmpty else {
            throw SyncV2ApplicationError.remoteSchedulingSuspensionRequired
        }
        activeAccountTransitionSuspensions.insert(suspensionToken.rawValue)
        defer { activeAccountTransitionSuspensions.remove(suspensionToken.rawValue) }
        try await kernel.transitionAccountScopes(from: old, to: new)
        guard remoteSchedulingSuspensions.contains(suspensionToken.rawValue) else {
            throw SyncV2ApplicationError.remoteSchedulingSuspensionRequired
        }
        historyScopeGeneration &+= 1
        let affectedWorkIDs = Set(workerTasks.keys)
            .union(workerOwners.keys)
            .union(states.keys)
            .union(sessions.keys)
        await planner.invalidateCaches(for: affectedWorkIDs)
        for workID in affectedWorkIDs {
            cancelWorker(for: workID)
            states[workID] = SyncUIState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .idle,
                conflict: nil,
                lastTypedResult: .checkpointed
            )
        }
    }

    /// Stops every old remote worker before an auth transition can checkpoint
    /// or swap the durable binding. Local checkpoints continue to commit while
    /// the lease is held; all worker wake paths observe the lease.
    public func beginAccountTransitionRemoteSuspension() -> SyncV2AccountTransitionRemoteSuspensionToken {
        let token = SyncV2AccountTransitionRemoteSuspensionToken()
        remoteSchedulingSuspensions.insert(token.rawValue)
        let affectedWorkIDs = Set(workerTasks.keys).union(workerOwners.keys)
        for workID in affectedWorkIDs {
            cancelWorker(for: workID)
        }
        return token
    }

    /// Releases exactly the supplied transition lease. A stale lease cannot
    /// resume a later auth operation. `resume` is used only when the durable
    /// transition failed and the old authenticated scope remains authoritative.
    @discardableResult
    public func endAccountTransitionRemoteSuspension(
        _ token: SyncV2AccountTransitionRemoteSuspensionToken,
        resume: Bool
    ) async -> Bool {
        guard !activeAccountTransitionSuspensions.contains(token.rawValue) else {
            return false
        }
        guard remoteSchedulingSuspensions.remove(token.rawValue) != nil else {
            return false
        }
        guard resume, remoteSchedulingSuspensions.isEmpty else { return true }
        do {
            try await resumePending()
            return true
        } catch {
            return false
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
