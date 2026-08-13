import CloudKit
import Foundation
import NovelSync

public extension CloudKitEpisodeSyncTransport {
    func createWork(_ descriptor: SyncWorkDescriptor) async throws {
        // Explicit first save is allowed to create the custom zone. `ensureZone`
        // only confirms an existing graph and would fail the empty-shelf window.
        try await bootstrapZoneForNewSync()
        let entity = try makeInitialNoteWorkRecord(descriptor)
        if let existing = try await fetchRecordIfPresent(.noteEntity(entity.key)) {
            let installed = try codec.decodeNoteRecord(existing)
            guard installed.key.workID == descriptor.workID,
                  case let .work(payload) = installed.payload,
                  payload.documentID.rawValue == descriptor.sourceDocumentID else {
                throw SyncCatalogError.duplicateWorkID
            }
            return
        }
        let encoded = try codec.makeNoteRecord(entity)
        defer {
            if let staged = encoded.stagedAsset {
                codec.removeStagedAssets([staged])
            }
        }
        changeDriver.enqueueNoteSaves([encoded.record])
        try await changeDriver.sendPendingChanges()
    }

    func listWorks() async throws -> [SyncWorkDescriptor] {
        try await ensureZone()
        let records = try await listWorkRecords()
        return try records.map { try SyncWorkDescriptor(noteWork: $0) }
            .sorted { $0.workID.rawValue.uuidString < $1.workID.rawValue.uuidString }
    }

    func listLibraryWorks() async throws -> [SyncWorkLibraryEntry] {
        try await ensureZone()
        let records = try await queryAllRecords(
            recordType: CloudKitSyncSchema.RecordType.noteWork
        )
        return CloudKitNoteLibraryRecordDecoder(codec: codec).decodeIsolatingMalformed(records)
    }
}

struct CloudKitWorkLibraryRecordDecoder {
    let codec: CloudKitRecordCodec

    func decode(_ controls: [CKRecord]) throws -> [SyncWorkLibraryEntry] {
        var entryByID: [SyncWorkID: SyncWorkLibraryEntry] = [:]
        for record in controls {
            let workID = try parseWorkID(from: record)
            guard entryByID[workID] == nil else {
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
            let control = try codec.decodeWorkControlRecord(record, expectedWorkID: workID)
            guard control.headRevisionID != nil else {
                // A durable local pending-create entry owns this state. A remote
                // descriptor without an immutable head is not downloadable and is
                // intentionally absent from the cloud shelf.
                continue
            }
            guard let entry = control.libraryEntry else {
                // D-063 is a development cutover. A head-bearing pre-library
                // control cannot prove current title/structure without fetching
                // its full asset and must be reset, not silently presented stale.
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
            entryByID[workID] = entry
        }
        return entryByID.values.sorted {
            $0.workID.rawValue.uuidString < $1.workID.rawValue.uuidString
        }
    }

    /// A malformed control must not hide every otherwise valid work in the shelf.
    /// The bad WorkID is omitted as a unit; duplicate IDs invalidate that work
    /// rather than letting record enumeration order choose a winner.
    func decodeIsolatingMalformed(_ controls: [CKRecord]) -> [SyncWorkLibraryEntry] {
        var entryByID: [SyncWorkID: SyncWorkLibraryEntry] = [:]
        var seenWorkIDs: Set<SyncWorkID> = []
        var invalidWorkIDs: Set<SyncWorkID> = []

        for record in controls {
            guard let workID = try? parseWorkID(from: record) else { continue }
            guard seenWorkIDs.insert(workID).inserted else {
                invalidWorkIDs.insert(workID)
                entryByID.removeValue(forKey: workID)
                continue
            }
            do {
                let control = try codec.decodeWorkControlRecord(record, expectedWorkID: workID)
                guard control.headRevisionID != nil else { continue }
                guard let entry = control.libraryEntry else {
                    throw CloudKitSyncAdapterError.invalidRemoteRecord
                }
                entryByID[workID] = entry
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

    private func parseWorkID(from record: CKRecord) throws -> SyncWorkID {
        do {
            return try SyncWorkID(
                rawValue: codec.parseCanonicalUUID(
                    codec.requiredString(record, CloudKitSyncSchema.Field.workID)
                )
            )
        } catch {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
    }
}

private extension CloudKitEpisodeSyncTransport {
    func requireCompatibleCreationControl(
        _ record: CKRecord,
        requested descriptor: SyncWorkDescriptor
    ) throws {
        let control = try codec.decodeWorkControlRecord(
            record,
            expectedWorkID: descriptor.workID
        )
        guard let entry = control.libraryEntry,
              entry.sourceDocumentID == descriptor.sourceDocumentID else {
            throw SyncCatalogError.duplicateWorkID
        }
        if control.headRevisionID == nil {
            guard try entry == SyncWorkLibraryEntry(descriptor: descriptor) else {
                throw SyncCatalogError.duplicateWorkID
            }
        }
    }

    func queryAllRecords(recordType: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
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

enum CloudKitWorkCreationMatcher {
    static func requireIdempotentRetry(
        existing: SyncWorkDescriptor,
        requested: SyncWorkDescriptor
    ) throws {
        guard existing == requested else {
            throw SyncCatalogError.duplicateWorkID
        }
    }
}

extension CloudKitEpisodeSyncTransport {
    func requireWorkExists(_ workID: SyncWorkID) async throws {
        let recordID = CKRecord.ID.syncWork(workID)
        guard let record = try await fetchRecordIfPresent(recordID) else {
            throw CloudKitSyncAdapterError.workNotFound
        }
        let descriptor = try codec.decodeWorkRecord(record)
        guard descriptor.workID == workID else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
    }
}
