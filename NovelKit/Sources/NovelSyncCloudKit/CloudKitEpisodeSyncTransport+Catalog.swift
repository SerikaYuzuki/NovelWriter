import CloudKit
import Foundation
import NovelSync

public extension CloudKitEpisodeSyncTransport {
    func createWork(_ descriptor: SyncWorkDescriptor) async throws {
        try await ensureZone()
        let record = try codec.makeWorkRecord(descriptor)
        if let existing = try await fetchRecordIfPresent(record.recordID) {
            try CloudKitWorkCreationMatcher.requireIdempotentRetry(
                existing: codec.decodeWorkRecord(existing),
                requested: descriptor
            )
            return
        }
        do {
            _ = try await modifyAtomically([record])
        } catch {
            if CloudKitErrorMapper.containsServerRecordChanged(error) {
                guard let existing = try await fetchRecordIfPresent(record.recordID) else {
                    throw SyncCatalogError.duplicateWorkID
                }
                try CloudKitWorkCreationMatcher.requireIdempotentRetry(
                    existing: codec.decodeWorkRecord(existing),
                    requested: descriptor
                )
                return
            }
            throw mappedOperationError(error)
        }
    }

    func listWorks() async throws -> [SyncWorkDescriptor] {
        try await ensureZone()
        let query = CKQuery(
            recordType: CloudKitSyncSchema.RecordType.work,
            predicate: NSPredicate(value: true)
        )
        var descriptors: [SyncWorkDescriptor] = []
        var page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
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
                    try descriptors.append(codec.decodeWorkRecord(record))
                case let .failure(error):
                    throw mappedOperationError(error)
                }
            }
            guard let cursor = page.queryCursor else { break }
            guard descriptors.count <= 10000 else {
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
            do {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            } catch {
                throw mappedOperationError(error)
            }
        }
        return descriptors.sorted { $0.workID.rawValue.uuidString < $1.workID.rawValue.uuidString }
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
