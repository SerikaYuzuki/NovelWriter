import CloudKit
import Foundation
import NovelSync

/// Apple transportだけが解釈するCloudKit schema。zoneは作品ごとに増やさず、
/// private database内の単一固定zoneへ全workを格納する。
enum CloudKitSyncSchema {
    static let protocolVersion: Int64 = 1
    static let zoneName = "FUMINIWA.DeviceSync.v1"
    static let subscriptionID = "FUMINIWA.DeviceSync.v1.private-zone"

    /// Source追加だけではproduction CloudKit schemaは更新されない。署名済み外部Gate前に
    /// この3 typeと下記fieldをDevelopmentからProductionへ明示deployする必要がある。
    static let workSyncProductionRecordTypes = [
        RecordType.workControl,
        RecordType.workRevision,
        RecordType.workMutationReceipt
    ]

    enum RecordType {
        static let work = "FUMINIWASyncWorkV1"
        static let episodeControl = "FUMINIWAEpisodeControlV1"
        static let episodeRevision = "FUMINIWAEpisodeRevisionV1"
        static let mutationReceipt = "FUMINIWAMutationReceiptV1"
        // D-061の作品単位revisionは既存の話単位schemaと同じprivate zoneを
        // 共有するが、production schemaをadditiveに展開できるようrecord typeを
        // 明示的に分ける。既存Episode recordをWork recordとして解釈しない。
        static let workControl = "FUMINIWAWorkControlV1"
        static let workRevision = "FUMINIWAWorkRevisionV1"
        static let workMutationReceipt = "FUMINIWAWorkMutationReceiptV1"
    }

    enum Field {
        static let protocolVersion = "protocolVersion"
        static let workID = "workID"
        static let sourceDocumentID = "sourceDocumentID"
        static let structureDigest = "structureDigest"
        static let title = "title"
        static let titleDigest = "titleDigest"
        static let titleUTF8ByteCount = "titleUTF8ByteCount"
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
        static let snapshotDigest = "snapshotDigest"
        static let snapshotByteCount = "snapshotByteCount"
        static let revisionDigest = "revisionDigest"
        static let revisionByteCount = "revisionByteCount"
        static let revisionAsset = "revisionAsset"
        static let attachmentManifestDigest = "attachmentManifestDigest"
        static let attachmentCount = "attachmentCount"
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

    static func workControl(_ workID: SyncWorkID) -> String {
        "\(workScope(workID)).control"
    }

    static func workRevision(_ revisionID: SyncRevisionID, workID: SyncWorkID) -> String {
        "\(workScope(workID)).revision.\(revisionID.rawValue.uuidString)"
    }

    static func workMutationReceipt(_ mutationID: SyncMutationID, workID: SyncWorkID) -> String {
        "\(workScope(workID)).mutation.\(mutationID.rawValue.uuidString)"
    }

    private static func episodeScope(_ key: EpisodeSyncKey) -> String {
        "\(prefix).work.\(key.workID.rawValue.uuidString).episode.\(key.episodeID.rawValue.uuidString)"
    }

    private static func workScope(_ workID: SyncWorkID) -> String {
        "\(prefix).work.\(workID.rawValue.uuidString).whole"
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

    static func workControl(_ workID: SyncWorkID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CloudKitSyncRecordNames.workControl(workID),
            zoneID: CloudKitSyncSchema.zoneID
        )
    }

    static func workRevision(_ revisionID: SyncRevisionID, workID: SyncWorkID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CloudKitSyncRecordNames.workRevision(revisionID, workID: workID),
            zoneID: CloudKitSyncSchema.zoneID
        )
    }

    static func workMutationReceipt(_ mutationID: SyncMutationID, workID: SyncWorkID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CloudKitSyncRecordNames.workMutationReceipt(mutationID, workID: workID),
            zoneID: CloudKitSyncSchema.zoneID
        )
    }
}
