import Foundation
import NovelSync

/// Development CloudKit で `TRUEPREDICATE` が `recordName` QUERYABLE を
/// 要求して CKError 12 / 2015 になる窓の catalog 補助。Production index の
/// 代替ではなく、同じ zone の Note work を別 predicate または engine 観測 ID
/// から record ID で拾う。
enum CloudKitNoteCatalogDiscovery {
    /// `TRUEPREDICATE` は `recordName` の QUERYABLE index を要求する。
    /// Development では `workID` だけが QUERYABLE なことが多く、entity fetch の
    /// `workID == uuid` は通っても棚の全件 query が 12/2015 になる。
    static func workIDPresentPredicate() -> NSPredicate {
        NSPredicate(
            format: "%K != %@",
            CloudKitSyncSchema.Field.workID,
            ""
        )
    }

    static func workIDHexPrefixPredicates() -> [NSPredicate] {
        Array("0123456789ABCDEF").map { prefix in
            NSPredicate(
                format: "%K BEGINSWITH %@",
                CloudKitSyncSchema.Field.workID,
                String(prefix)
            )
        }
    }

    static func modificationDatePredicate() -> NSPredicate {
        NSPredicate(
            format: "modificationDate > %@",
            Date.distantPast as NSDate
        )
    }

    static func modificationDateSortDescriptors() -> [NSSortDescriptor] {
        [NSSortDescriptor(key: "modificationDate", ascending: true)]
    }

    static func uniqueWorkIDs(fromRecordNames names: [String]) -> [SyncWorkID] {
        var seen: Set<SyncWorkID> = []
        var ordered: [SyncWorkID] = []
        for name in names {
            guard let workID = CloudKitSyncRecordNames.workID(fromNoteRecordName: name),
                  seen.insert(workID).inserted else { continue }
            ordered.append(workID)
        }
        return ordered.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
    }
}
