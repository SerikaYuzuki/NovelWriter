import CloudKit
import Foundation
import NovelSync

/// Development schema may materialize Note types on first save before the
/// custom `workID` QUERYABLE index exists. `CKQuery` on that field then maps
/// to `.invalidArguments`. Catalog scan plus in-memory WorkID filter is the
/// fallback; it is not a substitute for deploying the index.
enum CloudKitNoteWorkIDQuery {
    static func shouldScanType(after error: any Error) -> Bool {
        if let adapter = error as? CloudKitSyncAdapterError {
            return allowsTypeScan(adapter)
        }
        return allowsTypeScan(CloudKitErrorMapper.map(error))
    }

    static func matching(_ workID: SyncWorkID, in records: [CKRecord]) -> [CKRecord] {
        let expected = workID.rawValue.uuidString
        return records.filter { record in
            (record[CloudKitSyncSchema.Field.workID] as? String) == expected
        }
    }

    private static func allowsTypeScan(_ error: CloudKitSyncAdapterError) -> Bool {
        switch error {
        case .invalidArguments:
            true
        case let .partialFailure(kinds):
            kinds.contains(.invalidArguments)
        default:
            false
        }
    }
}
