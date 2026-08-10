import CloudKit
import Foundation
import NovelSync

/// Apple transportだけが解釈するCloudKit schema。zoneは作品ごとに増やさず、
/// private database内の単一固定zoneへ全workを格納する。
enum CloudKitSyncSchema {
    static let protocolVersion: Int64 = 1
    static let zoneName = "FUMINIWA.DeviceSync.v1"
    static let subscriptionID = "FUMINIWA.DeviceSync.v1.private-zone"

    enum RecordType {
        static let work = "FUMINIWASyncWorkV1"
        static let episodeControl = "FUMINIWAEpisodeControlV1"
        static let episodeRevision = "FUMINIWAEpisodeRevisionV1"
        static let mutationReceipt = "FUMINIWAMutationReceiptV1"
    }

    enum Field {
        static let protocolVersion = "protocolVersion"
        static let workID = "workID"
        static let sourceDocumentID = "sourceDocumentID"
        static let structureDigest = "structureDigest"
        static let title = "title"
        static let episodeID = "episodeID"
        static let headRevisionID = "headRevisionID"
        static let holderReplicaID = "holderReplicaID"
        static let holderSessionID = "holderSessionID"
        static let leaseEpoch = "leaseEpoch"
        static let leaseExpiresAt = "leaseExpiresAt"
        static let revisionID = "revisionID"
        static let parentRevisionIDs = "parentRevisionIDs"
        static let branchID = "branchID"
        static let authorReplicaID = "authorReplicaID"
        static let authorSessionID = "authorSessionID"
        static let clientCreatedAt = "clientCreatedAt"
        static let bodyDigest = "bodyDigest"
        static let bodyByteCount = "bodyByteCount"
        static let bodyAsset = "bodyAsset"
        static let mutationID = "mutationID"
        static let commandDigest = "commandDigest"
        static let resultHeadRevisionID = "resultHeadRevisionID"
        static let resultLeaseEpoch = "resultLeaseEpoch"
        static let resultHolderReplicaID = "resultHolderReplicaID"
        static let resultHolderSessionID = "resultHolderSessionID"
        static let resultLeaseExpiresAt = "resultLeaseExpiresAt"
    }

    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
}

enum CloudKitSyncRecordNames {
    private static let prefix = "v1"

    static func work(_ workID: SyncWorkID) -> String {
        "\(prefix).work.\(workID.rawValue.uuidString)"
    }

    static func episodeControl(_ key: EpisodeSyncKey) -> String {
        "\(episodeScope(key)).control"
    }

    static func revision(_ revisionID: SyncRevisionID, key: EpisodeSyncKey) -> String {
        "\(episodeScope(key)).revision.\(revisionID.rawValue.uuidString)"
    }

    static func mutationReceipt(_ mutationID: SyncMutationID, key: EpisodeSyncKey) -> String {
        "\(episodeScope(key)).mutation.\(mutationID.rawValue.uuidString)"
    }

    private static func episodeScope(_ key: EpisodeSyncKey) -> String {
        "\(prefix).work.\(key.workID.rawValue.uuidString).episode.\(key.episodeID.rawValue.uuidString)"
    }
}

extension CKRecord.ID {
    static func syncWork(_ workID: SyncWorkID) -> CKRecord.ID {
        CKRecord.ID(recordName: CloudKitSyncRecordNames.work(workID), zoneID: CloudKitSyncSchema.zoneID)
    }

    static func episodeControl(_ key: EpisodeSyncKey) -> CKRecord.ID {
        CKRecord.ID(recordName: CloudKitSyncRecordNames.episodeControl(key), zoneID: CloudKitSyncSchema.zoneID)
    }

    static func episodeRevision(_ revisionID: SyncRevisionID, key: EpisodeSyncKey) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CloudKitSyncRecordNames.revision(revisionID, key: key),
            zoneID: CloudKitSyncSchema.zoneID
        )
    }

    static func mutationReceipt(_ mutationID: SyncMutationID, key: EpisodeSyncKey) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CloudKitSyncRecordNames.mutationReceipt(mutationID, key: key),
            zoneID: CloudKitSyncSchema.zoneID
        )
    }
}
