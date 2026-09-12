import NovelSyncV2Store

/// Encoding-only payloads; all validation and sequencing remain in the planner.
struct CommandEnvelope<Payload: Encodable>: Encodable {
    let binding: CommandBinding
    let commandId: String
    let commandKind: String
    let payload: Payload
    let schemaVersion: Int
    let sourceGeneration: Int64
    let sourceSnapshotId: String
}

struct CommandBinding: Encodable {
    let accountFence: String
    let accountId: String
    let protocolEpoch: Int64
    let serverInstanceId: String

    init(binding: V2AccountBinding) {
        accountFence = binding.accountFence
        accountId = binding.accountID
        protocolEpoch = binding.protocolEpoch
        serverInstanceId = binding.serverInstanceID
    }
}

struct CommandHead: Encodable {
    let generation: Int64
    let snapshotId: String

    init(_ head: V2RemoteHead) {
        generation = head.generation
        snapshotId = head.snapshotID.rawValue
    }
}

struct PublishPayload: Encodable {
    let candidateSnapshotId: String
    let expectedRemoteHead: CommandHead?
    let workId: String
}

struct CreateWorkPayload: Encodable { let documentId: String; let workId: String }
struct PrepareObjectPayload: Encodable { let byteCount: Int; let objectId: String; let workId: String }
struct FinalizeObjectPayload: Encodable { let byteCount: Int; let objectId: String; let uploadId: String; let workId: String }
struct RegisterSnapshotPayload: Encodable { let manifestBase64URL: String; let manifestBytesDigest: String; let snapshotId: String; let workId: String }
struct ResolveServerPayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let expectedCurrentSnapshotId: String
    let expectedLocalGeneration: Int64
    let preAdoptionSnapshotId: String
    let remoteSnapshotId: String
    let workId: String
}

struct ResolveDevicePayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let decisionSnapshotId: String
    let expectedRemoteHead: CommandHead
    let localCandidateSnapshotId: String
    let workId: String
}

struct CloneWorkPayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let expectedOriginalHead: CommandHead
    let localCandidateSnapshotId: String
    let newDocumentId: String
    let newRootSnapshotId: String
    let newWorkId: String
    let sourceWorkId: String
}
