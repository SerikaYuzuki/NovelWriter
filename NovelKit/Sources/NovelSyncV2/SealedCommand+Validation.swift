import Foundation

extension SealedCommand {
    static func validateEnvelope(_ root: [String: CanonicalJSON.Value]) throws {
        let expectedFields: Set = [
            "binding",
            "commandId",
            "commandKind",
            "payload",
            "schemaVersion",
            "sourceGeneration",
            "sourceSnapshotId"
        ]
        guard Set(root.keys) == expectedFields else {
            throw SyncV2TypeError.commandViolation("envelope fields")
        }
        guard case let .number(version) = root["schemaVersion"],
              version == 2,
              case let .string(kind) = root["commandKind"],
              kinds.contains(kind) else {
            throw SyncV2TypeError.commandViolation("kind/version")
        }
    }

    static func decodeBinding(_ pairs: [(String, CanonicalJSON.Value)]) throws -> Binding {
        let fields = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard Set(fields.keys) == Set(["accountFence", "accountId", "protocolEpoch", "serverInstanceId"]),
              case let .string(fence) = fields["accountFence"],
              fence.count >= 1,
              fence.count <= 256,
              case let .string(account) = fields["accountId"],
              account.count >= 1,
              account.count <= 128,
              case let .number(epoch) = fields["protocolEpoch"],
              epoch >= 1,
              case let .string(server) = fields["serverInstanceId"],
              server.count >= 1,
              server.count <= 128 else {
            throw SyncV2TypeError.commandViolation("binding")
        }
        return Binding(
            accountFence: fence,
            accountId: account,
            protocolEpoch: epoch,
            serverInstanceId: server
        )
    }

    static func validatePayload(_ kind: String, _ value: CanonicalJSON.Value) throws {
        guard case let .object(pairs) = value else {
            throw SyncV2TypeError.commandViolation("payload")
        }
        let fields = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard Set(fields.keys) == expectedPayloadFields(for: kind) else {
            throw SyncV2TypeError.commandViolation("payload fields")
        }
        for (key, fieldValue) in fields {
            try validatePayloadField(key: key, value: fieldValue)
        }
    }

    private static func expectedPayloadFields(for kind: String) -> Set<String> {
        payloadFieldsByKind[kind] ?? []
    }

    private static let payloadFieldsByKind: [String: Set<String>] = [
        "createWork": ["documentId", "workId"],
        "prepareObject": ["byteCount", "objectId", "workId"],
        "finalizeObject": ["byteCount", "objectId", "uploadId", "workId"],
        "registerSnapshot": ["manifestBase64URL", "manifestBytesDigest", "snapshotId", "workId"],
        "publish": ["candidateSnapshotId", "expectedRemoteHead", "workId"],
        "resolveDevice": [
            "conflictId",
            "conflictRevision",
            "decisionSnapshotId",
            "expectedRemoteHead",
            "localCandidateSnapshotId",
            "workId"
        ],
        "resolveServer": [
            "conflictId",
            "conflictRevision",
            "expectedCurrentSnapshotId",
            "expectedLocalGeneration",
            "preAdoptionSnapshotId",
            "remoteSnapshotId",
            "workId"
        ],
        "cloneWork": [
            "conflictId",
            "conflictRevision",
            "expectedOriginalHead",
            "localCandidateSnapshotId",
            "newDocumentId",
            "newRootSnapshotId",
            "newWorkId",
            "sourceWorkId"
        ],
        "restore": [
            "expectedCurrentSnapshotId",
            "expectedLocalGeneration",
            "expectedRemoteHead",
            "newSnapshotId",
            "selectedSnapshotId",
            "workId"
        ]
    ]

    private static func validatePayloadField(
        key: String,
        value: CanonicalJSON.Value
    ) throws {
        switch key {
        case "byteCount":
            try validateByteCount(value, key: key)
        case "conflictRevision", "expectedLocalGeneration":
            try validatePositiveInteger(value, key: key)
        case "workId", "documentId", "uploadId", "conflictId", "newWorkId", "newDocumentId":
            try validateUUID(value, key: key)
        case "objectId", "manifestBytesDigest", "snapshotId", "candidateSnapshotId",
             "decisionSnapshotId", "localCandidateSnapshotId", "expectedCurrentSnapshotId",
             "preAdoptionSnapshotId", "remoteSnapshotId", "newRootSnapshotId", "selectedSnapshotId":
            try validateDigest(value, key: key)
        case "manifestBase64URL":
            try validateManifestBase64URL(value, key: key)
        case "expectedRemoteHead", "expectedOriginalHead":
            try validateHead(value, key: key)
        default:
            break
        }
    }

    private static func validateByteCount(
        _ value: CanonicalJSON.Value,
        key: String
    ) throws {
        guard case let .number(number) = value,
              number >= 0,
              number <= Int64(SnapshotSyncV2Limits.maxObjectBytes) else {
            throw SyncV2TypeError.commandViolation(key)
        }
    }

    private static func validatePositiveInteger(
        _ value: CanonicalJSON.Value,
        key: String
    ) throws {
        guard case let .number(number) = value,
              number >= 1,
              number <= 9_007_199_254_740_991 else {
            throw SyncV2TypeError.commandViolation(key)
        }
    }

    private static func validateUUID(
        _ value: CanonicalJSON.Value,
        key: String
    ) throws {
        guard case let .string(string) = value,
              SyncV2UUID.parse(string) != nil else {
            throw SyncV2TypeError.commandViolation(key)
        }
    }

    private static func validateDigest(
        _ value: CanonicalJSON.Value,
        key: String
    ) throws {
        guard case let .string(string) = value,
              (try? ObjectID(rawValue: string)) != nil else {
            throw SyncV2TypeError.commandViolation(key)
        }
    }

    private static func validateManifestBase64URL(
        _ value: CanonicalJSON.Value,
        key: String
    ) throws {
        guard case let .string(string) = value,
              string.count >= 2,
              string.count <= SnapshotSyncV2Limits.maxManifestBase64URLCharacters,
              string.range(
                  of: #"^(?:[A-Za-z0-9_-]{4})*(?:[A-Za-z0-9_-]{2}|[A-Za-z0-9_-]{3})?$"#,
                  options: .regularExpression
              ) != nil else {
            throw SyncV2TypeError.commandViolation(key)
        }
    }

    private static func validateHead(
        _ value: CanonicalJSON.Value,
        key: String
    ) throws {
        if case .null = value {
            return
        }
        guard case let .object(pairs) = value else {
            throw SyncV2TypeError.commandViolation(key)
        }
        let fields = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard Set(fields.keys) == Set(["generation", "snapshotId"]),
              case let .number(generation) = fields["generation"],
              generation >= 1,
              let snapshotID = fields["snapshotId"] else {
            throw SyncV2TypeError.commandViolation(key)
        }
        try validateDigest(snapshotID, key: "snapshotId")
    }
}
