// Conflict detection and 3-choice resolution share one transport-neutral unit.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable function_parameter_count type_body_length
import Foundation

public enum NoteSyncReconcileError: Error, Equatable, Sendable {
    case workIDMismatch
    case unassemblable
    case missingConflict
    case newWorkIDCollision
}

public struct NoteSyncRemoteDelta: Equatable, Sendable {
    public var upserts: [NoteSyncRecord]
    public var deletedKeys: [NoteSyncEntityKey]

    public static let none = NoteSyncRemoteDelta(upserts: [], deletedKeys: [])

    public init(upserts: [NoteSyncRecord], deletedKeys: [NoteSyncEntityKey] = []) {
        self.upserts = upserts
        self.deletedKeys = deletedKeys
    }
}

public struct NoteSyncConflict: Equatable, Sendable {
    public let workID: SyncWorkID
    public let keys: Set<NoteSyncEntityKey>

    public init(workID: SyncWorkID, keys: Set<NoteSyncEntityKey>) {
        self.workID = workID
        self.keys = keys
    }
}

public struct NoteSyncReconcileResult: Equatable, Sendable {
    public let appliedSnapshot: WorkSnapshot
    public let recordsToSend: [NoteSyncRecord]
    public let keysToDelete: [NoteSyncEntityKey]
    public let conflict: NoteSyncConflict?

    public init(
        appliedSnapshot: WorkSnapshot,
        recordsToSend: [NoteSyncRecord],
        keysToDelete: [NoteSyncEntityKey],
        conflict: NoteSyncConflict?
    ) {
        self.appliedSnapshot = appliedSnapshot
        self.recordsToSend = recordsToSend
        self.keysToDelete = keysToDelete
        self.conflict = conflict
    }
}

public enum NoteSyncConflictChoice: Equatable, Sendable {
    case keepLocal
    case keepRemote
    case keepBoth
}

public struct NoteSyncResolution: Equatable, Sendable {
    public let currentWorkSnapshot: WorkSnapshot
    public let currentSend: [NoteSyncRecord]
    public let currentDeletes: [NoteSyncEntityKey]
    public let currentAcked: [NoteSyncEntityKey: SyncContentDigest]
    public let currentDirty: NoteSyncDirtySet
    public let currentForceSendKeys: Set<NoteSyncEntityKey>
    public let forkedWorkID: SyncWorkID?
    public let forkedSnapshot: WorkSnapshot?
    public let forkedRecords: [NoteSyncRecord]

    public init(
        currentWorkSnapshot: WorkSnapshot,
        currentSend: [NoteSyncRecord],
        currentDeletes: [NoteSyncEntityKey],
        currentAcked: [NoteSyncEntityKey: SyncContentDigest],
        currentDirty: NoteSyncDirtySet,
        currentForceSendKeys: Set<NoteSyncEntityKey>,
        forkedWorkID: SyncWorkID?,
        forkedSnapshot: WorkSnapshot?,
        forkedRecords: [NoteSyncRecord]
    ) {
        self.currentWorkSnapshot = currentWorkSnapshot
        self.currentSend = currentSend
        self.currentDeletes = currentDeletes
        self.currentAcked = currentAcked
        self.currentDirty = currentDirty
        self.currentForceSendKeys = currentForceSendKeys
        self.forkedWorkID = forkedWorkID
        self.forkedSnapshot = forkedSnapshot
        self.forkedRecords = forkedRecords
    }
}

public enum NoteSyncReconciler {
    public static func unsyncedChanges(
        localRecords: [NoteSyncRecord],
        lastAcked: [NoteSyncEntityKey: SyncContentDigest]
    ) -> NoteSyncDirtySet {
        let local = Dictionary(uniqueKeysWithValues: localRecords.map { ($0.key, $0) })
        var saves: Set<NoteSyncEntityKey> = []
        var deletes: Set<NoteSyncEntityKey> = []
        for key in Set(local.keys).union(lastAcked.keys) {
            let localDigest = local[key]?.digest
            let acked = lastAcked[key]
            if localDigest == nil, acked != nil {
                deletes.insert(key)
            } else if let localDigest, localDigest != acked {
                saves.insert(key)
            }
        }
        return NoteSyncDirtySet(saves: saves, deletes: deletes)
    }

    public static func reconcile(
        workID: SyncWorkID,
        local: WorkSnapshot,
        remote: NoteSyncRemoteDelta,
        dirty: NoteSyncDirtySet,
        lastAcked: [NoteSyncEntityKey: SyncContentDigest],
        forceSendKeys: Set<NoteSyncEntityKey> = []
    ) throws -> NoteSyncReconcileResult {
        let localRecords = try NoteSyncProjection.records(workID: workID, snapshot: local)
        let localMap = try NoteSyncProjection.keyedRecords(localRecords, workID: workID)
        let remoteMap = try NoteSyncProjection.keyedRecords(remote.upserts, workID: workID)
        let remoteDeletes = Set(remote.deletedKeys)
        guard remoteDeletes.allSatisfy({ $0.workID == workID }) else {
            throw NoteSyncReconcileError.workIDMismatch
        }
        let dirtySet = try dirty.validated()
        var conflictKeys = conflictKeys(
            local: localMap,
            remote: remoteMap,
            remoteDeletes: remoteDeletes,
            dirty: dirtySet,
            lastAcked: lastAcked,
            forceSendKeys: forceSendKeys
        )

        let applied = try assembleApplyingRemote(
            workID: workID,
            local: localMap,
            remote: remoteMap,
            remoteDeletes: remoteDeletes,
            dirty: dirtySet,
            conflictKeys: &conflictKeys
        )
        let recordsToSend = dirtySet.saves.subtracting(conflictKeys).sorted().compactMap { key -> NoteSyncRecord? in
            guard let localRecord = localMap[key] else { return nil }
            if localRecord.digest == remoteMap[key]?.digest {
                return nil
            }
            return localRecord
        }
        let keysToDelete = dirtySet.deletes.subtracting(conflictKeys).sorted()
        let conflict = conflictKeys.isEmpty
            ? nil
            : NoteSyncConflict(workID: workID, keys: conflictKeys)
        return NoteSyncReconcileResult(
            appliedSnapshot: applied,
            recordsToSend: recordsToSend,
            keysToDelete: keysToDelete,
            conflict: conflict
        )
    }

    public static func resolve(
        _ choice: NoteSyncConflictChoice,
        workID: SyncWorkID,
        local: WorkSnapshot,
        remote: NoteSyncRemoteDelta,
        dirty: NoteSyncDirtySet,
        lastAcked: [NoteSyncEntityKey: SyncContentDigest],
        conflictKeys: Set<NoteSyncEntityKey>,
        newWorkID: SyncWorkID
    ) throws -> NoteSyncResolution {
        guard !conflictKeys.isEmpty else {
            throw NoteSyncReconcileError.missingConflict
        }
        let localRecords = try NoteSyncProjection.records(workID: workID, snapshot: local)
        let localMap = try NoteSyncProjection.keyedRecords(localRecords, workID: workID)
        let remoteMap = try NoteSyncProjection.keyedRecords(remote.upserts, workID: workID)
        let remoteDeletes = Set(remote.deletedKeys)

        switch choice {
        case .keepLocal:
            return try resolveKeepLocal(
                workID: workID,
                localMap: localMap,
                remoteMap: remoteMap,
                remoteDeletes: remoteDeletes,
                dirty: dirty,
                lastAcked: lastAcked,
                conflictKeys: conflictKeys
            )
        case .keepRemote:
            return try resolveKeepRemote(
                workID: workID,
                localMap: localMap,
                remoteMap: remoteMap,
                remoteDeletes: remoteDeletes,
                dirty: dirty,
                lastAcked: lastAcked,
                conflictKeys: conflictKeys
            )
        case .keepBoth:
            return try resolveKeepBoth(
                workID: workID,
                local: local,
                remoteMap: remoteMap,
                newWorkID: newWorkID
            )
        }
    }

    private static func resolveKeepLocal(
        workID: SyncWorkID,
        localMap: [NoteSyncEntityKey: NoteSyncRecord],
        remoteMap: [NoteSyncEntityKey: NoteSyncRecord],
        remoteDeletes: Set<NoteSyncEntityKey>,
        dirty: NoteSyncDirtySet,
        lastAcked: [NoteSyncEntityKey: SyncContentDigest],
        conflictKeys: Set<NoteSyncEntityKey>
    ) throws -> NoteSyncResolution {
        var merged = localMap
        for (key, record) in remoteMap where !conflictKeys.contains(key) && !dirty.contains(key) {
            merged[key] = record
        }
        for key in remoteDeletes where !conflictKeys.contains(key) && !dirty.contains(key) {
            merged.removeValue(forKey: key)
        }
        let snapshot = try NoteSyncProjection.snapshot(workID: workID, records: Array(merged.values))
        let send = conflictKeys.sorted().compactMap { localMap[$0] }
        let deletes = conflictKeys.sorted().filter { localMap[$0] == nil }
        return NoteSyncResolution(
            currentWorkSnapshot: snapshot,
            currentSend: send,
            currentDeletes: deletes,
            currentAcked: lastAcked,
            currentDirty: dirty,
            currentForceSendKeys: conflictKeys,
            forkedWorkID: nil,
            forkedSnapshot: nil,
            forkedRecords: []
        )
    }

    private static func resolveKeepRemote(
        workID: SyncWorkID,
        localMap: [NoteSyncEntityKey: NoteSyncRecord],
        remoteMap: [NoteSyncEntityKey: NoteSyncRecord],
        remoteDeletes: Set<NoteSyncEntityKey>,
        dirty: NoteSyncDirtySet,
        lastAcked: [NoteSyncEntityKey: SyncContentDigest],
        conflictKeys: Set<NoteSyncEntityKey>
    ) throws -> NoteSyncResolution {
        var merged = localMap
        var acked = lastAcked
        var nextDirty = dirty
        for key in conflictKeys {
            if let remoteRecord = remoteMap[key] {
                merged[key] = remoteRecord
                acked[key] = remoteRecord.digest
            } else if remoteDeletes.contains(key) {
                merged.removeValue(forKey: key)
                acked.removeValue(forKey: key)
            }
            nextDirty.saves.remove(key)
            nextDirty.deletes.remove(key)
        }
        let snapshot = try NoteSyncProjection.snapshot(workID: workID, records: Array(merged.values))
        return NoteSyncResolution(
            currentWorkSnapshot: snapshot,
            currentSend: [],
            currentDeletes: [],
            currentAcked: acked,
            currentDirty: nextDirty,
            currentForceSendKeys: [],
            forkedWorkID: nil,
            forkedSnapshot: nil,
            forkedRecords: []
        )
    }

    private static func resolveKeepBoth(
        workID: SyncWorkID,
        local: WorkSnapshot,
        remoteMap: [NoteSyncEntityKey: NoteSyncRecord],
        newWorkID: SyncWorkID
    ) throws -> NoteSyncResolution {
        guard newWorkID != workID else {
            throw NoteSyncReconcileError.newWorkIDCollision
        }
        let remoteSnapshot = try NoteSyncProjection.snapshot(
            workID: workID,
            records: Array(remoteMap.values)
        )
        let acked = Dictionary(uniqueKeysWithValues: remoteMap.map { ($0.key, $0.value.digest) })
        let forkedRecords = try NoteSyncProjection.records(workID: newWorkID, snapshot: local)
        return NoteSyncResolution(
            currentWorkSnapshot: remoteSnapshot,
            currentSend: [],
            currentDeletes: [],
            currentAcked: acked,
            currentDirty: .empty,
            currentForceSendKeys: [],
            forkedWorkID: newWorkID,
            forkedSnapshot: local,
            forkedRecords: forkedRecords
        )
    }

    private static func conflictKeys(
        local: [NoteSyncEntityKey: NoteSyncRecord],
        remote: [NoteSyncEntityKey: NoteSyncRecord],
        remoteDeletes: Set<NoteSyncEntityKey>,
        dirty: NoteSyncDirtySet,
        lastAcked: [NoteSyncEntityKey: SyncContentDigest],
        forceSendKeys: Set<NoteSyncEntityKey>
    ) -> Set<NoteSyncEntityKey> {
        var keys: Set<NoteSyncEntityKey> = []
        for key in Set(local.keys).union(remote.keys).union(remoteDeletes).union(dirty.saves).union(dirty.deletes) {
            guard dirty.contains(key), !forceSendKeys.contains(key) else { continue }
            let localDigest = local[key]?.digest
            let remoteDigest = remote[key]?.digest
            if let remoteDigest, localDigest == remoteDigest {
                continue
            }
            let acked = lastAcked[key]
            let remoteChanged = remote[key] != nil && remoteDigest != acked
            let remotelyDeleted = remoteDeletes.contains(key)
            if remoteChanged || remotelyDeleted {
                keys.insert(key)
            }
        }
        return keys
    }

    private static func assembleApplyingRemote(
        workID: SyncWorkID,
        local: [NoteSyncEntityKey: NoteSyncRecord],
        remote: [NoteSyncEntityKey: NoteSyncRecord],
        remoteDeletes: Set<NoteSyncEntityKey>,
        dirty: NoteSyncDirtySet,
        conflictKeys: inout Set<NoteSyncEntityKey>
    ) throws -> WorkSnapshot {
        let structureKinds: Set<NoteSyncEntityKind> = [.work, .chapter]
        while true {
            let merged = mergedRecords(
                local: local,
                remote: remote,
                remoteDeletes: remoteDeletes,
                dirty: dirty,
                conflictKeys: conflictKeys
            )
            do {
                return try NoteSyncProjection.snapshot(workID: workID, records: Array(merged.values))
            } catch {
                let extra = Set(remote.keys).union(remoteDeletes)
                    .subtracting(conflictKeys)
                    .filter { key in
                        !dirty.contains(key) && structureKinds.contains(key.kind)
                    }
                guard !extra.isEmpty else {
                    throw NoteSyncReconcileError.unassemblable
                }
                conflictKeys.formUnion(extra)
            }
        }
    }

    private static func mergedRecords(
        local: [NoteSyncEntityKey: NoteSyncRecord],
        remote: [NoteSyncEntityKey: NoteSyncRecord],
        remoteDeletes: Set<NoteSyncEntityKey>,
        dirty: NoteSyncDirtySet,
        conflictKeys: Set<NoteSyncEntityKey>
    ) -> [NoteSyncEntityKey: NoteSyncRecord] {
        var merged = local
        for (key, record) in remote where !conflictKeys.contains(key) && !dirty.contains(key) {
            merged[key] = record
        }
        for key in remoteDeletes where !conflictKeys.contains(key) && !dirty.contains(key) {
            merged.removeValue(forKey: key)
        }
        return merged
    }
}
