import Foundation

public struct SealedCommand: Hashable, Sendable {
    public let commandId: UUID
    public let commandKind: String
    public let sourceGeneration: Int64
    public let sourceSnapshotId: SnapshotID
    public let binding: Binding
    public let payloadBytes: Data
    public let canonicalBytes: Data
    public let requestDigest: ObjectID

    public struct Binding: Hashable, Sendable {
        public let accountFence: String
        public let accountId: String
        public let protocolEpoch: Int64
        public let serverInstanceId: String
        public init(accountFence: String, accountId: String, protocolEpoch: Int64, serverInstanceId: String) {
            self.accountFence = accountFence; self.accountId = accountId; self.protocolEpoch = protocolEpoch; self.serverInstanceId = serverInstanceId
        }
    }

    public static let kinds: Set<String> = ["cloneWork", "createWork", "finalizeObject", "prepareObject", "publish", "registerSnapshot", "resolveDevice", "resolveServer", "restore"]

    public static func decodeCanonical(_ data: Data) throws -> SealedCommand {
        guard case let .object(pairs) = try CanonicalJSON.parseObject(data) else { throw SyncV2TypeError.commandViolation("envelope") }
        let root = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard Set(root.keys) == Set(["binding", "commandId", "commandKind", "payload", "schemaVersion", "sourceGeneration", "sourceSnapshotId"]) else { throw SyncV2TypeError.commandViolation("envelope fields") }
        guard case let .number(version) = root["schemaVersion"], version == 2, case let .string(kind) = root["commandKind"], kinds.contains(kind) else { throw SyncV2TypeError.commandViolation("kind/version") }
        guard let commandString = root["commandId"]?.stringValue, let commandID = SyncV2UUID.parse(commandString) else { throw SyncV2TypeError.invalidUUID }
        guard case let .number(generation) = root["sourceGeneration"], generation >= 1, case let .string(snapshotString) = root["sourceSnapshotId"], let sourceSnapshot = try? SnapshotID(rawValue: snapshotString) else { throw SyncV2TypeError.commandViolation("source") }
        guard case let .object(bindingPairs) = root["binding"] else { throw SyncV2TypeError.commandViolation("binding") }
        let b = Dictionary(bindingPairs, uniquingKeysWith: { first, _ in first })
        guard Set(b.keys) == Set(["accountFence", "accountId", "protocolEpoch", "serverInstanceId"]),
              case let .string(fence) = b["accountFence"], fence.count >= 1, fence.count <= 256,
              case let .string(account) = b["accountId"], account.count >= 1, account.count <= 128,
              case let .number(epoch) = b["protocolEpoch"], epoch >= 1,
              case let .string(server) = b["serverInstanceId"], server.count >= 1, server.count <= 128 else {
            throw SyncV2TypeError.commandViolation("binding")
        }
        guard let payload = root["payload"], case .object = payload else { throw SyncV2TypeError.commandViolation("payload") }
        try validatePayload(kind, payload)
        let payloadBytes = try CanonicalJSON.render(payload)
        return SealedCommand(commandId: commandID, commandKind: kind, sourceGeneration: generation, sourceSnapshotId: sourceSnapshot, binding: Binding(accountFence: fence, accountId: account, protocolEpoch: epoch, serverInstanceId: server), payloadBytes: payloadBytes, canonicalBytes: data, requestDigest: ObjectID(data: data))
    }

    public static func requestDigest(for canonicalBytes: Data) -> ObjectID {
        ObjectID(data: canonicalBytes)
    }

    public static func isCanonical(_ data: Data) -> Bool {
        (try? decodeCanonical(data)) != nil
    }

    private init(commandId: UUID, commandKind: String, sourceGeneration: Int64, sourceSnapshotId: SnapshotID, binding: Binding, payloadBytes: Data, canonicalBytes: Data, requestDigest: ObjectID) {
        self.commandId = commandId; self.commandKind = commandKind; self.sourceGeneration = sourceGeneration; self.sourceSnapshotId = sourceSnapshotId; self.binding = binding; self.payloadBytes = payloadBytes; self.canonicalBytes = canonicalBytes; self.requestDigest = requestDigest
    }

    private static func validatePayload(_ kind: String, _ value: CanonicalJSON.Value) throws {
        guard case let .object(pairs) = value else { throw SyncV2TypeError.commandViolation("payload") }
        let f = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let expected: Set<String>
        switch kind {
        case "createWork": expected = ["documentId", "workId"]
        case "prepareObject": expected = ["byteCount", "objectId", "workId"]
        case "finalizeObject": expected = ["byteCount", "objectId", "uploadId", "workId"]
        case "registerSnapshot": expected = ["manifestBase64URL", "manifestBytesDigest", "snapshotId", "workId"]
        case "publish": expected = ["candidateSnapshotId", "expectedRemoteHead", "workId"]
        case "resolveDevice": expected = ["conflictId", "conflictRevision", "decisionSnapshotId", "expectedRemoteHead", "localCandidateSnapshotId", "workId"]
        case "resolveServer": expected = ["conflictId", "conflictRevision", "expectedCurrentSnapshotId", "expectedLocalGeneration", "preAdoptionSnapshotId", "remoteSnapshotId", "workId"]
        case "cloneWork": expected = ["conflictId", "conflictRevision", "expectedOriginalHead", "localCandidateSnapshotId", "newDocumentId", "newRootSnapshotId", "newWorkId", "sourceWorkId"]
        case "restore": expected = ["expectedCurrentSnapshotId", "expectedLocalGeneration", "expectedRemoteHead", "newSnapshotId", "selectedSnapshotId", "workId"]
        default: throw SyncV2TypeError.commandViolation("kind")
        }
        guard Set(f.keys) == expected else { throw SyncV2TypeError.commandViolation("payload fields") }
        for (key, value) in f {
            switch key {
            case "byteCount": guard case let .number(n) = value, n >= 0, n <= 262_144_000 else { throw SyncV2TypeError.commandViolation(key) }
            case "conflictRevision", "expectedLocalGeneration": guard case let .number(n) = value, n >= 1, n <= 9_007_199_254_740_991 else { throw SyncV2TypeError.commandViolation(key) }
            case "workId", "documentId", "uploadId", "conflictId", "newWorkId", "newDocumentId": try uuid(value, key)
            case "objectId", "manifestBytesDigest", "snapshotId", "candidateSnapshotId", "decisionSnapshotId", "localCandidateSnapshotId", "expectedCurrentSnapshotId", "preAdoptionSnapshotId", "remoteSnapshotId", "newRootSnapshotId", "selectedSnapshotId": try digest(value, key)
            case "manifestBase64URL": guard case let .string(s) = value, s.range(of: #"^(?:[A-Za-z0-9_-]{4})*(?:[A-Za-z0-9_-]{2}|[A-Za-z0-9_-]{3})?$"#, options: .regularExpression) != nil, s.count >= 2 else { throw SyncV2TypeError.commandViolation(key) }
            case "expectedRemoteHead", "expectedOriginalHead": try head(value, key)
            default: break
            }
        }
    }

    private static func uuid(_ value: CanonicalJSON.Value, _ key: String) throws {
        guard case let .string(s) = value, SyncV2UUID.parse(s) != nil else { throw SyncV2TypeError.commandViolation(key) }
    }

    private static func digest(_ value: CanonicalJSON.Value, _ key: String) throws {
        guard case let .string(s) = value, (try? ObjectID(rawValue: s)) != nil else { throw SyncV2TypeError.commandViolation(key) }
    }

    private static func head(_ value: CanonicalJSON.Value, _ key: String) throws {
        if case .null = value {
            return
        }; guard case let .object(pairs) = value else { throw SyncV2TypeError.commandViolation(key) }; let f = Dictionary(pairs, uniquingKeysWith: { first, _ in first }); guard Set(f.keys) == Set(["generation", "snapshotId"]), case let .number(g) = f["generation"], g >= 1 else { throw SyncV2TypeError.commandViolation(key) }; try digest(f["snapshotId"]!, "snapshotId")
    }
}

private extension CanonicalJSON.Value {
    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }; return nil
    }
}
