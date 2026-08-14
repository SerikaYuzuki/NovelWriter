import CloudKit
import Foundation
import NovelSync

/// CKSyncEngineへ渡すNote recordのpending本体。Episode/Work CASのrecordは載せない。
final class CloudKitNotePendingMailbox: @unchecked Sendable {
    static let maximumObservedNoteWorkIDCount = 1088

    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var savedIDs: Set<CKRecord.ID> = []
    private var failedSaves: [CKRecord.ID: CKError] = [:]
    private var observedNoteWorkIDSet: Set<SyncWorkID> = []

    func store(_ record: CKRecord) {
        lock.lock()
        records[record.recordID] = record
        lock.unlock()
    }

    func store(_ incoming: [CKRecord]) {
        lock.lock()
        for record in incoming {
            records[record.recordID] = record
        }
        lock.unlock()
    }

    func record(for recordID: CKRecord.ID) -> CKRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[recordID]
    }

    func remove(_ recordID: CKRecord.ID) {
        lock.lock()
        records.removeValue(forKey: recordID)
        lock.unlock()
    }

    func remove(ids: [CKRecord.ID]) {
        lock.lock()
        for id in ids {
            records.removeValue(forKey: id)
        }
        lock.unlock()
    }

    func beginSend() {
        lock.lock()
        savedIDs.removeAll()
        failedSaves.removeAll()
        lock.unlock()
    }

    func recordSendOutcome(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        lock.lock()
        for record in sent.savedRecords {
            records.removeValue(forKey: record.recordID)
            savedIDs.insert(record.recordID)
            failedSaves.removeValue(forKey: record.recordID)
        }
        for recordID in sent.deletedRecordIDs {
            records.removeValue(forKey: recordID)
            savedIDs.insert(recordID)
            failedSaves.removeValue(forKey: recordID)
        }
        for failure in sent.failedRecordSaves {
            failedSaves[failure.record.recordID] = failure.error
        }
        for (recordID, error) in sent.failedRecordDeletes {
            failedSaves[recordID] = error
        }
        recordObservedNoteWorkIDsLocked(
            fromRecordNames: sent.savedRecords.map(\.recordID.recordName)
        )
        lock.unlock()
    }

    func recordObservedNoteWorkIDs(fromRecordNames names: [String]) {
        lock.lock()
        recordObservedNoteWorkIDsLocked(fromRecordNames: names)
        lock.unlock()
    }

    func observedNoteWorkIDs() -> [SyncWorkID] {
        lock.lock()
        defer { lock.unlock() }
        return observedNoteWorkIDSet.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
    }

    func clearObservedNoteWorkIDs() {
        lock.lock()
        observedNoteWorkIDSet.removeAll()
        lock.unlock()
    }

    private func recordObservedNoteWorkIDsLocked(fromRecordNames names: [String]) {
        for name in names {
            guard observedNoteWorkIDSet.count < Self.maximumObservedNoteWorkIDCount,
                  let workID = CloudKitSyncRecordNames.workID(fromNoteRecordName: name) else {
                continue
            }
            observedNoteWorkIDSet.insert(workID)
        }
    }

    func takeSendOutcome() -> CloudKitNoteSendOutcome {
        lock.lock()
        defer { lock.unlock() }
        let outcome = CloudKitNoteSendOutcome(savedIDs: savedIDs, failedSaves: failedSaves)
        savedIDs.removeAll()
        failedSaves.removeAll()
        return outcome
    }
}

enum CloudKitNotePendingQueue {
    static func isNoteRecordName(_ recordName: String) -> Bool {
        CloudKitSyncRecordNames.isNoteEntity(recordName)
    }

    static func noteChanges(
        from pending: [CKSyncEngine.PendingRecordZoneChange]
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        pending.filter { change in
            switch change {
            case let .saveRecord(recordID), let .deleteRecord(recordID):
                isNoteRecordName(recordID.recordName)
            @unknown default:
                false
            }
        }
    }

    static func orderedSaveRecords(_ records: [CKRecord]) -> [CKRecord] {
        records.sorted { lhs, rhs in
            let lhsIsWork = lhs.recordType == CloudKitSyncSchema.RecordType.noteWork
            let rhsIsWork = rhs.recordType == CloudKitSyncSchema.RecordType.noteWork
            if lhsIsWork != rhsIsWork {
                return lhsIsWork
            }
            return lhs.recordID.recordName < rhs.recordID.recordName
        }
    }
}

enum CloudKitNoteConflictInspector {
    static func classifySaves(
        incoming: [NoteSyncRecord],
        existing: [NoteSyncEntityKey: NoteSyncRecord],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) -> (accepted: [NoteSyncRecord], identical: [NoteSyncRecord], conflicts: [NoteSyncRecord]) {
        var accepted: [NoteSyncRecord] = []
        var identical: [NoteSyncRecord] = []
        var conflicts: [NoteSyncRecord] = []
        for record in incoming {
            if let current = existing[record.key],
               !forceOverwrite.contains(record.key) {
                if current.digest == record.digest {
                    identical.append(record)
                    continue
                }
                if current.digest != expectedDigests[record.key] {
                    conflicts.append(current)
                    continue
                }
            }
            accepted.append(record)
        }
        return (accepted, identical, conflicts)
    }

    static func classifyDeletes(
        keys: [NoteSyncEntityKey],
        existing: [NoteSyncEntityKey: NoteSyncRecord],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) -> (accepted: [NoteSyncEntityKey], conflicts: [NoteSyncRecord]) {
        var accepted: [NoteSyncEntityKey] = []
        var conflicts: [NoteSyncRecord] = []
        for key in keys {
            if let current = existing[key],
               !forceOverwrite.contains(key),
               current.digest != expectedDigests[key] {
                conflicts.append(current)
                continue
            }
            accepted.append(key)
        }
        return (accepted, conflicts)
    }
}

struct CloudKitNoteSendOutcome: Sendable {
    var savedIDs: Set<CKRecord.ID> = []
    var failedSaves: [CKRecord.ID: CKError] = [:]

    mutating func formUnion(_ other: CloudKitNoteSendOutcome) {
        savedIDs.formUnion(other.savedIDs)
        for (recordID, error) in other.failedSaves {
            failedSaves[recordID] = error
        }
        savedIDs.subtract(failedSaves.keys)
    }

    func apply(
        intended: [NoteSyncRecord],
        existingConflicts: [NoteSyncRecord],
        decodeServerRecord: (CKRecord) throws -> NoteSyncRecord
    ) throws -> (accepted: [NoteSyncRecord], conflicts: [NoteSyncRecord]) {
        var accepted: [NoteSyncRecord] = []
        var conflicts = existingConflicts
        for record in intended {
            let recordID = CKRecord.ID.noteEntity(record.key)
            if savedIDs.contains(recordID) {
                accepted.append(record)
                continue
            }
            guard let error = failedSaves[recordID] else {
                CloudKitSyncDiagnostic.log("note-sync send pending unacked")
                throw CloudKitSyncAdapterError.operationFailed
            }
            if CloudKitErrorMapper.containsServerRecordChanged(error),
               let ckRecord = error.serverRecord
               ?? error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                try conflicts.append(decodeServerRecord(ckRecord))
                continue
            }
            throw CloudKitErrorMapper.map(error)
        }
        return (accepted, conflicts)
    }
}
