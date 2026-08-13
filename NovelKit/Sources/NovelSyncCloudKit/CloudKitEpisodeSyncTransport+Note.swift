import CloudKit
import Foundation
import NovelSync

extension CloudKitEpisodeSyncTransport: NoteSyncCloudStore, NoteSyncLibraryFetching {
    public func save(
        _ records: [NoteSyncRecord],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult {
        try await ensureZone()
        let existing = try await fetchNoteEntities(Array(Set(records.map(\.key))))
        let classified = CloudKitNoteConflictInspector.classifySaves(
            incoming: records,
            existing: existing,
            expectedDigests: expectedDigests,
            forceOverwrite: forceOverwrite
        )
        var stagedAssets: [CloudKitStagedAsset] = []
        defer { codec.removeStagedAssets(stagedAssets) }
        var encoded: [CKRecord] = []
        encoded.reserveCapacity(classified.accepted.count)
        for entity in classified.accepted {
            let existingRecord = try await fetchRecordIfPresent(.noteEntity(entity.key))
            let encodedRecord = try codec.makeNoteRecord(entity, existing: existingRecord)
            if let staged = encodedRecord.stagedAsset {
                stagedAssets.append(staged)
            }
            encoded.append(encodedRecord.record)
        }
        var outcome = CloudKitNoteSendOutcome()
        if !encoded.isEmpty {
            let workFirst = CloudKitNotePendingQueue.orderedSaveRecords(encoded)
            let workRecords = workFirst.filter { $0.recordType == CloudKitSyncSchema.RecordType.noteWork }
            let childRecords = workFirst.filter { $0.recordType != CloudKitSyncSchema.RecordType.noteWork }
            if !workRecords.isEmpty {
                changeDriver.enqueueNoteSaves(workRecords)
                try await changeDriver.sendPendingChanges()
                outcome.formUnion(changeDriver.takeNoteSendOutcome())
            }
            if !childRecords.isEmpty {
                changeDriver.enqueueNoteSaves(childRecords)
                try await changeDriver.sendPendingChanges()
                outcome.formUnion(changeDriver.takeNoteSendOutcome())
            }
        }
        let applied = try outcome.apply(
            intended: classified.accepted,
            existingConflicts: classified.conflicts
        ) { record in
            try codec.decodeNoteRecord(record)
        }
        return NoteSyncSendResult(
            acceptedSaves: applied.accepted,
            conflictedKeys: Set(applied.conflicts.map(\.key)),
            conflictedRemoteRecords: applied.conflicts
        )
    }

    public func delete(
        _ keys: [NoteSyncEntityKey],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult {
        try await ensureZone()
        let existing = try await fetchNoteEntities(keys)
        let classified = CloudKitNoteConflictInspector.classifyDeletes(
            keys: keys,
            existing: existing,
            expectedDigests: expectedDigests,
            forceOverwrite: forceOverwrite
        )
        var outcome = CloudKitNoteSendOutcome()
        if !classified.accepted.isEmpty {
            changeDriver.enqueueNoteDeletes(classified.accepted.map { .noteEntity($0) })
            try await changeDriver.sendPendingChanges()
            outcome.formUnion(changeDriver.takeNoteSendOutcome())
        }
        var acceptedDeletes: [NoteSyncEntityKey] = []
        var conflicts = classified.conflicts
        for key in classified.accepted {
            let recordID = CKRecord.ID.noteEntity(key)
            if outcome.savedIDs.contains(recordID) {
                acceptedDeletes.append(key)
                continue
            }
            if let error = outcome.failedSaves[recordID] {
                if CloudKitErrorMapper.containsServerRecordChanged(error),
                   let ckRecord = error.serverRecord
                   ?? error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    try conflicts.append(codec.decodeNoteRecord(ckRecord))
                    continue
                }
                throw CloudKitErrorMapper.map(error)
            }
        }
        return NoteSyncSendResult(
            acceptedDeletes: acceptedDeletes,
            conflictedKeys: Set(conflicts.map(\.key)),
            conflictedRemoteRecords: conflicts
        )
    }

    public func fetchAll(for workID: SyncWorkID) async throws -> [NoteSyncRecord] {
        try await ensureZone()
        var records: [NoteSyncRecord] = []
        var usedWorkIDQuery = true
        for recordType in CloudKitSyncSchema.noteSyncProductionRecordTypes {
            let fetched = try await fetchNoteRecords(recordType: recordType, workID: workID)
            if fetched.usedTypeScan {
                usedWorkIDQuery = false
            }
            for record in fetched.records {
                try records.append(codec.decodeNoteRecord(record))
            }
        }
        if !usedWorkIDQuery {
            print("[FUMINIWA] note-sync fetch used type scan because workID query is unavailable")
        }
        return records.sorted { $0.key < $1.key }
    }

    public func fetchNoteRecords(for workID: SyncWorkID) async throws -> [NoteSyncRecord] {
        try await fetchAll(for: workID)
    }

    public func listWorkRecords() async throws -> [NoteSyncRecord] {
        try await ensureZone()
        let fetched = try await queryRecords(
            recordType: CloudKitSyncSchema.RecordType.noteWork,
            predicate: NSPredicate(value: true)
        )
        return try fetched.map { try codec.decodeNoteRecord($0) }.sorted { $0.key < $1.key }
    }

    func makeInitialNoteWorkRecord(_ descriptor: SyncWorkDescriptor) throws -> NoteSyncRecord {
        let payload = NoteSyncWorkPayload(
            documentID: WorkStableID(rawValue: descriptor.sourceDocumentID),
            title: descriptor.title,
            synopsis: "",
            chapterOrder: [],
            characterOrder: [],
            plotCardOrder: [],
            flagOrder: [],
            worldNoteOrder: []
        )
        return try NoteSyncRecord(key: .work(descriptor.workID), payload: .work(payload))
    }

    private func fetchNoteEntities(
        _ keys: [NoteSyncEntityKey]
    ) async throws -> [NoteSyncEntityKey: NoteSyncRecord] {
        guard !keys.isEmpty else { return [:] }
        let fetched = try await fetchRecordsIfPresent(keys.map { .noteEntity($0) })
        var decoded: [NoteSyncEntityKey: NoteSyncRecord] = [:]
        for (_, record) in fetched {
            let entity = try codec.decodeNoteRecord(record)
            decoded[entity.key] = entity
        }
        return decoded
    }

    private func fetchNoteRecords(
        recordType: String,
        workID: SyncWorkID
    ) async throws -> (records: [CKRecord], usedTypeScan: Bool) {
        do {
            let fetched = try await queryRecords(
                recordType: recordType,
                predicate: NSPredicate(
                    format: "%K == %@",
                    CloudKitSyncSchema.Field.workID,
                    workID.rawValue.uuidString
                )
            )
            return (fetched, false)
        } catch {
            guard CloudKitNoteWorkIDQuery.shouldScanType(after: error) else { throw error }
            let scanned = try await queryRecords(
                recordType: recordType,
                predicate: NSPredicate(value: true)
            )
            return (CloudKitNoteWorkIDQuery.matching(workID, in: scanned), true)
        }
    }

    private func queryRecords(recordType: String, predicate: NSPredicate) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        var records: [CKRecord] = []
        var page: (
            matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
            queryCursor: CKQueryOperation.Cursor?
        )
        do {
            page = try await database.records(
                matching: query,
                inZoneWith: CloudKitSyncSchema.zoneID,
                resultsLimit: CKQueryOperation.maximumResults
            )
        } catch {
            throw mappedOperationError(error)
        }
        while true {
            for (_, result) in page.matchResults {
                switch result {
                case let .success(record):
                    records.append(record)
                case let .failure(error):
                    throw mappedOperationError(error)
                }
            }
            guard records.count <= 10000 else {
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
            guard let cursor = page.queryCursor else { break }
            do {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            } catch {
                throw mappedOperationError(error)
            }
        }
        return records
    }
}

struct CloudKitNoteLibraryRecordDecoder {
    let codec: CloudKitRecordCodec

    func decodeIsolatingMalformed(_ records: [CKRecord]) -> [SyncWorkLibraryEntry] {
        var entryByID: [SyncWorkID: SyncWorkLibraryEntry] = [:]
        var seenWorkIDs: Set<SyncWorkID> = []
        var invalidWorkIDs: Set<SyncWorkID> = []

        for record in records {
            guard let entity = try? codec.decodeNoteRecord(record),
                  entity.key.kind == .work else { continue }
            let workID = entity.key.workID
            guard seenWorkIDs.insert(workID).inserted else {
                invalidWorkIDs.insert(workID)
                entryByID.removeValue(forKey: workID)
                continue
            }
            do {
                entryByID[workID] = try SyncWorkLibraryEntry(noteWork: entity)
            } catch {
                invalidWorkIDs.insert(workID)
                entryByID.removeValue(forKey: workID)
            }
        }
        for workID in invalidWorkIDs {
            entryByID.removeValue(forKey: workID)
        }
        return entryByID.values.sorted {
            $0.workID.rawValue.uuidString < $1.workID.rawValue.uuidString
        }
    }
}
