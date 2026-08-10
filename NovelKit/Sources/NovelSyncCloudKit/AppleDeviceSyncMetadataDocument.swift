import Foundation
import NovelCore
import NovelSync

struct AppleDeviceSyncBindingRecord: Codable, Sendable {
    let locator: AppleLocalDocumentLocator
    let binding: SyncWorkingCopyBinding
    let allowedEpisodeIDs: [EpisodeID]
}

struct ApplePendingWorkCreationRecord: Codable, Sendable {
    let locator: AppleLocalDocumentLocator
    let descriptor: SyncWorkDescriptor
    let allowedEpisodeIDs: [EpisodeID]
}

struct AppleDeviceSyncMetadataDocument: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case replicaID
        case accountScope
        case bindings
        case pendingWorkCreations
        case engineStateGeneration
        case engineState
    }

    var schemaVersion: Int
    var replicaID: SyncReplicaID
    var accountScope: AppleCloudAccountScope?
    var bindings: [AppleDeviceSyncBindingRecord]
    var pendingWorkCreations: [ApplePendingWorkCreationRecord]
    var engineStateGeneration: UInt64
    var engineState: Data?

    init(
        schemaVersion: Int,
        replicaID: SyncReplicaID,
        accountScope: AppleCloudAccountScope?,
        bindings: [AppleDeviceSyncBindingRecord],
        pendingWorkCreations: [ApplePendingWorkCreationRecord],
        engineStateGeneration: UInt64,
        engineState: Data?
    ) {
        self.schemaVersion = schemaVersion
        self.replicaID = replicaID
        self.accountScope = accountScope
        self.bindings = bindings
        self.pendingWorkCreations = pendingWorkCreations
        self.engineStateGeneration = engineStateGeneration
        self.engineState = engineState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        replicaID = try container.decode(SyncReplicaID.self, forKey: .replicaID)
        accountScope = try container.decodeIfPresent(
            AppleCloudAccountScope.self,
            forKey: .accountScope
        )
        bindings = try container.decode([AppleDeviceSyncBindingRecord].self, forKey: .bindings)
        // schema v1へのadditive field。旧metadataにはこのkeyがない。
        pendingWorkCreations = try container.decodeIfPresent(
            [ApplePendingWorkCreationRecord].self,
            forKey: .pendingWorkCreations
        ) ?? []
        engineStateGeneration = try container.decode(
            UInt64.self,
            forKey: .engineStateGeneration
        )
        engineState = try container.decodeIfPresent(Data.self, forKey: .engineState)
    }
}
