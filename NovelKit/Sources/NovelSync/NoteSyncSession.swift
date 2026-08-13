import Foundation

/// package正本の外側でdirty setを更新し、entity recordの送信／取込／3択を純関数へ渡す。
public actor NoteSyncSession {
    public let workID: SyncWorkID
    private let store: any NoteSyncStateStore
    private var cached: NoteSyncState?

    public init(workID: SyncWorkID, store: any NoteSyncStateStore) {
        self.workID = workID
        self.store = store
    }

    public func state() async throws -> NoteSyncState {
        try await currentState()
    }

    public func recordLocalSnapshot(_ snapshot: WorkSnapshot) async throws -> NoteSyncDirtySet {
        let records = try NoteSyncProjection.records(workID: workID, snapshot: snapshot)
        var state = try await currentState()
        state.dirty = NoteSyncReconciler.unsyncedChanges(
            localRecords: records,
            lastAcked: state.lastAckedDigests
        )
        try await persist(state)
        return state.dirty
    }

    public func installFromRemote(_ records: [NoteSyncRecord]) async throws -> WorkSnapshot {
        let snapshot = try NoteSyncProjection.snapshot(workID: workID, records: records)
        let keyed = try NoteSyncProjection.keyedRecords(records, workID: workID)
        let state = NoteSyncState(
            workID: workID,
            dirty: .empty,
            lastAckedDigests: Dictionary(uniqueKeysWithValues: keyed.map { ($0.key, $0.value.digest) })
        )
        try await persist(state)
        return snapshot
    }

    public func reconcile(
        local: WorkSnapshot,
        remote: NoteSyncRemoteDelta
    ) async throws -> NoteSyncReconcileResult {
        let state = try await currentState()
        let result = try NoteSyncReconciler.reconcile(
            workID: workID,
            local: local,
            remote: remote,
            dirty: state.dirty,
            lastAcked: state.lastAckedDigests,
            forceSendKeys: state.forceSendKeys
        )
        var next = state
        next.pendingConflictKeys = result.conflict?.keys ?? []
        try await persist(next)
        return result
    }

    public func acknowledge(
        sent: [NoteSyncRecord] = [],
        deletedKeys: [NoteSyncEntityKey] = [],
        applied: [NoteSyncRecord] = []
    ) async throws {
        var state = try await currentState()
        for record in sent + applied {
            guard record.key.workID == workID else {
                throw NoteSyncStateError.workMismatch
            }
            state.lastAckedDigests[record.key] = record.digest
            state.dirty.saves.remove(record.key)
            state.forceSendKeys.remove(record.key)
            state.pendingConflictKeys.remove(record.key)
        }
        for key in deletedKeys {
            guard key.workID == workID else {
                throw NoteSyncStateError.workMismatch
            }
            state.lastAckedDigests.removeValue(forKey: key)
            state.dirty.deletes.remove(key)
            state.forceSendKeys.remove(key)
            state.pendingConflictKeys.remove(key)
        }
        try await persist(state)
    }

    public func resolve(
        _ choice: NoteSyncConflictChoice,
        local: WorkSnapshot,
        remote: NoteSyncRemoteDelta,
        newWorkID: SyncWorkID
    ) async throws -> NoteSyncResolution {
        let state = try await currentState()
        let conflictKeys = state.pendingConflictKeys
        let resolution = try NoteSyncReconciler.resolve(
            choice,
            workID: workID,
            local: local,
            remote: remote,
            dirty: state.dirty,
            lastAcked: state.lastAckedDigests,
            conflictKeys: conflictKeys,
            newWorkID: newWorkID
        )
        let next = NoteSyncState(
            workID: workID,
            dirty: resolution.currentDirty,
            lastAckedDigests: resolution.currentAcked,
            pendingConflictKeys: [],
            forceSendKeys: resolution.currentForceSendKeys
        )
        try await persist(next)
        return resolution
    }

    private func currentState() async throws -> NoteSyncState {
        if let cached {
            return cached
        }
        let loaded = try await store.load(for: workID) ?? .empty(workID: workID)
        cached = loaded
        return loaded
    }

    private func persist(_ state: NoteSyncState) async throws {
        try state.validate()
        try await store.save(state)
        cached = state
    }
}
