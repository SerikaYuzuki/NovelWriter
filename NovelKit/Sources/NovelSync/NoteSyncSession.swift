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
        // Increment on every observation, including an identical snapshot. The
        // caller captures the token after this method returns; a later save
        // therefore invalidates an older in-flight network response.
        let dirtyKeys = state.dirty.saves.union(state.dirty.deletes)
        state.dirtyGenerations = state.dirtyGenerations.filter { dirtyKeys.contains($0.key) }
        for key in dirtyKeys {
            state.dirtyGenerations[key, default: 0] &+= 1
        }
        try await persist(state)
        return state.dirty
    }

    public func dirtyGenerations(
        for keys: Set<NoteSyncEntityKey>
    ) async throws -> [NoteSyncEntityKey: Int] {
        let state = try await currentState()
        return state.dirtyGenerations.filter { keys.contains($0.key) }
    }

    public func installFromRemote(_ records: [NoteSyncRecord]) async throws -> WorkSnapshot {
        let snapshot = try NoteSyncProjection.snapshot(workID: workID, records: records)
        let keyed = try NoteSyncProjection.keyedRecords(records, workID: workID)
        let state = NoteSyncState(
            workID: workID,
            dirty: .empty,
            lastAckedDigests: Dictionary(uniqueKeysWithValues: keyed.map { ($0.key, $0.value.digest) }),
            dirtyGenerations: [:]
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
        applied: [NoteSyncRecord] = [],
        expectedGenerations: [NoteSyncEntityKey: Int] = [:]
    ) async throws {
        var state = try await currentState()
        for record in sent + applied {
            guard record.key.workID == workID else {
                throw NoteSyncStateError.workMismatch
            }
            guard expectedGenerations[record.key] == nil
                || state.dirtyGenerations[record.key] == expectedGenerations[record.key] else {
                continue
            }
            state.lastAckedDigests[record.key] = record.digest
            state.dirty.saves.remove(record.key)
            state.forceSendKeys.remove(record.key)
            state.pendingConflictKeys.remove(record.key)
            state.dirtyGenerations.removeValue(forKey: record.key)
        }
        for key in deletedKeys {
            guard key.workID == workID else {
                throw NoteSyncStateError.workMismatch
            }
            guard expectedGenerations[key] == nil
                || state.dirtyGenerations[key] == expectedGenerations[key] else {
                continue
            }
            state.lastAckedDigests.removeValue(forKey: key)
            state.dirty.deletes.remove(key)
            state.forceSendKeys.remove(key)
            state.pendingConflictKeys.remove(key)
            state.dirtyGenerations.removeValue(forKey: key)
        }
        try await persist(state)
    }

    public func resolve(
        _ choice: NoteSyncConflictChoice,
        local: WorkSnapshot,
        remote: NoteSyncRemoteDelta,
        newWorkID: SyncWorkID,
        expectedKeys: Set<NoteSyncEntityKey> = []
    ) async throws -> NoteSyncResolution {
        let state = try await currentState()
        let conflictKeys = state.pendingConflictKeys.isEmpty
            ? expectedKeys
            : state.pendingConflictKeys
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
        // Deliberately do not persist here. The package/fork is the durable
        // side of a resolution and the app commits this state only after its
        // exact readback succeeds.
        return NoteSyncResolution(
            currentWorkSnapshot: resolution.currentWorkSnapshot,
            currentSend: resolution.currentSend,
            currentDeletes: resolution.currentDeletes,
            currentAcked: resolution.currentAcked,
            currentDirty: resolution.currentDirty,
            currentForceSendKeys: resolution.currentForceSendKeys,
            forkedWorkID: resolution.forkedWorkID,
            forkedSnapshot: resolution.forkedSnapshot,
            forkedRecords: resolution.forkedRecords,
            resolvedKeys: conflictKeys,
            expectedGenerations: state.dirtyGenerations.filter { conflictKeys.contains($0.key) }
        )
    }

    /// Commits the state half of a conflict resolution after the caller has
    /// durably installed the selected package (and fork, when requested).
    public func commitResolution(_ resolution: NoteSyncResolution) async throws {
        var state = try await currentState()
        let sentByKey = Dictionary(uniqueKeysWithValues: resolution.currentSend.map { ($0.key, $0) })
        for key in resolution.resolvedKeys {
            guard resolution.expectedGenerations[key] == nil
                || state.dirtyGenerations[key] == resolution.expectedGenerations[key] else {
                continue
            }
            if let record = sentByKey[key] {
                state.lastAckedDigests[key] = record.digest
                state.dirty.saves.remove(key)
                state.dirty.deletes.remove(key)
            } else if resolution.currentDeletes.contains(key) {
                state.lastAckedDigests.removeValue(forKey: key)
                state.dirty.saves.remove(key)
                state.dirty.deletes.remove(key)
            } else if let digest = resolution.currentAcked[key] {
                state.lastAckedDigests[key] = digest
                state.dirty.saves.remove(key)
                state.dirty.deletes.remove(key)
            } else {
                state.lastAckedDigests.removeValue(forKey: key)
                state.dirty.saves.remove(key)
                state.dirty.deletes.remove(key)
            }
            state.forceSendKeys.remove(key)
            state.pendingConflictKeys.remove(key)
            state.dirtyGenerations.removeValue(forKey: key)
        }
        try await persist(state)
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
