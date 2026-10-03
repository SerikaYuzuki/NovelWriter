import Foundation
import NovelSyncV2

/// One fully validated current snapshot. No document/payload copy is retained.
struct CheckpointValidationStamp: Equatable {
    let workID: WorkID
    let scope: V2LocalWorkScope
    let snapshotID: Data?
    let generation: Int64
    let documentID: String?
    let documentCreatedAt: String?
    let dataVersion: Int64
    let totalChanges: Int64
}

public extension LocalSyncV2Store {
    /// Autosave scope validation; opening/importing never uses this shortcut.
    func validateCheckpointBase(workID: WorkID, scope: V2LocalWorkScope) throws {
        guard let row = try workRepository.scopedWorkRow(workID: workID, scope: scope) else {
            checkpointValidation = nil
            throw SyncV2StoreError.workNotFound
        }
        _ = try validatedCheckpointBase(workID: workID, scope: scope, row: row)
    }

    func invalidateCheckpointValidation() {
        checkpointValidation = nil
    }
}

extension LocalSyncV2Store {
    func checkpointDataVersion() throws -> Int64 {
        guard let value = try query("PRAGMA data_version").first?.scalar.int64 else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return value
    }

    func checkpointStamp(workID: WorkID, scope: V2LocalWorkScope, row: WorkRow) throws -> CheckpointValidationStamp {
        guard let generation = row.localGeneration,
              let changes = try query("SELECT total_changes()").first?.scalar.int64 else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try CheckpointValidationStamp(
            workID: workID,
            scope: scope,
            snapshotID: row.currentSnapshotID,
            generation: generation,
            documentID: row.documentID,
            documentCreatedAt: row.documentCreatedAt,
            dataVersion: checkpointDataVersion(),
            totalChanges: changes
        )
    }

    func validatedCheckpointBase(
        workID: WorkID,
        scope: V2LocalWorkScope,
        row: WorkRow
    ) throws -> CheckpointValidationStamp {
        let stamp = try checkpointStamp(workID: workID, scope: scope, row: row)
        if checkpointValidation == stamp {
            return stamp
        }
        _ = try fullyValidatedOpen(workID: workID, scope: scope)
        guard let validated = checkpointValidation, validated == stamp else {
            throw SyncV2StoreError.generationMismatch
        }
        return validated
    }

    /// Open always validates all bytes. Only a stable, successful full read
    /// seeds the next autosave; process reopen itself never restores a token.
    func fullyValidatedOpen(workID: WorkID, scope: V2LocalWorkScope) throws -> V2OpenResult {
        checkpointValidation = nil
        guard let row = try workRepository.scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.workNotFound
        }
        let before = try checkpointStamp(workID: workID, scope: scope, row: row)
        checkpointFullValidationCount += 1
        let opened = try workRepository.open(workID: workID, scope: scope)
        rememberStableRead(before)
        return opened
    }

    /// A successful full read retains the original open result even if another
    /// handle wrote during it. Only cache reuse requires the additional stability
    /// attestation; bookkeeping errors or external writes simply leave no stamp.
    func rememberStableRead(_ before: CheckpointValidationStamp) {
        checkpointValidation = nil
        guard let latest = try? workRepository.scopedWorkRow(workID: before.workID, scope: before.scope),
              let after = try? checkpointStamp(workID: before.workID, scope: before.scope, row: latest),
              after == before else { return }
        checkpointValidation = before
    }

    /// Whitelisted Store operations cannot modify current payload/entries or
    /// resources. Never bless an already stale token, even after a harmless write.
    /// Bookkeeping is best-effort and cannot turn a committed write into failure.
    func preservingCheckpointValidation<T>(_ body: () throws -> T) throws -> T {
        let before = checkpointValidation.flatMap { cached -> CheckpointValidationStamp? in
            guard let row = try? workRepository.scopedWorkRow(workID: cached.workID, scope: cached.scope),
                  let current = try? checkpointStamp(workID: cached.workID, scope: cached.scope, row: row),
                  current == cached else { return nil }
            return cached
        }
        checkpointValidation = nil
        let result = try body()
        if let before,
           let row = try? workRepository.scopedWorkRow(workID: before.workID, scope: before.scope),
           let after = try? checkpointStamp(workID: before.workID, scope: before.scope, row: row),
           before.hasSameValidatedContent(as: after) {
            checkpointValidation = after
        }
        return result
    }

    func inCheckpointNeutralTransaction<T>(_ body: () throws -> T) throws -> T {
        try preservingCheckpointValidation { try executor.inTransaction(body) }
    }

    /// Called only after COMMIT. A cache bookkeeping failure cannot undo or
    /// report failure for a durable save; it merely forces next-time validation.
    func rememberCheckpoint(_ result: V2CheckpointResult, workID: WorkID, scope: V2LocalWorkScope, dataVersion: Int64) {
        checkpointValidation = nil
        guard let row = try? workRepository.scopedWorkRow(workID: workID, scope: scope),
              let stamp = try? checkpointStamp(workID: workID, scope: scope, row: row),
              stamp.snapshotID == result.snapshotID.bytes,
              stamp.generation == result.generation,
              stamp.dataVersion == dataVersion else { return }
        checkpointValidation = stamp
    }
}

extension CheckpointValidationStamp {
    func hasSameValidatedContent(as other: Self) -> Bool {
        workID == other.workID && scope == other.scope && snapshotID == other.snapshotID &&
            generation == other.generation && documentID == other.documentID &&
            documentCreatedAt == other.documentCreatedAt && dataVersion == other.dataVersion
    }
}
