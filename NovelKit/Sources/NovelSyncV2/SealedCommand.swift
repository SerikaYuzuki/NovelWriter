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

        public init(
            accountFence: String,
            accountId: String,
            protocolEpoch: Int64,
            serverInstanceId: String
        ) {
            self.accountFence = accountFence
            self.accountId = accountId
            self.protocolEpoch = protocolEpoch
            self.serverInstanceId = serverInstanceId
        }
    }

    public static let kinds: Set<String> = [
        "cloneWork",
        "createWork",
        "finalizeObject",
        "prepareObject",
        "publish",
        "registerSnapshot",
        "resolveDevice",
        "resolveServer",
        "restore"
    ]

    public static func decodeCanonical(_ data: Data) throws -> SealedCommand {
        guard data.count <= SnapshotSyncV2Limits.maxCommandBytes else {
            throw SyncV2TypeError.commandViolation("size")
        }
        guard case let .object(pairs) = try CanonicalJSON.parseObject(
            data,
            maxBytes: SnapshotSyncV2Limits.maxCommandBytes
        ) else {
            throw SyncV2TypeError.commandViolation("envelope")
        }

        let root = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        try validateEnvelope(root)

        guard case let .string(kind) = root["commandKind"] else {
            throw SyncV2TypeError.commandViolation("kind/version")
        }
        guard let commandString = root["commandId"]?.stringValue,
              let commandID = SyncV2UUID.parse(commandString) else {
            throw SyncV2TypeError.invalidUUID
        }
        guard case let .number(generation) = root["sourceGeneration"],
              generation >= 1,
              case let .string(snapshotString) = root["sourceSnapshotId"],
              let sourceSnapshot = try? SnapshotID(rawValue: snapshotString) else {
            throw SyncV2TypeError.commandViolation("source")
        }
        guard case let .object(bindingPairs) = root["binding"] else {
            throw SyncV2TypeError.commandViolation("binding")
        }
        guard let payload = root["payload"], case .object = payload else {
            throw SyncV2TypeError.commandViolation("payload")
        }

        let binding = try decodeBinding(bindingPairs)
        try validatePayload(kind, payload)
        let payloadBytes = try CanonicalJSON.render(payload)
        return SealedCommand(
            commandId: commandID,
            commandKind: kind,
            sourceGeneration: generation,
            sourceSnapshotId: sourceSnapshot,
            binding: binding,
            payloadBytes: payloadBytes,
            canonicalBytes: data,
            requestDigest: ObjectID(data: data)
        )
    }

    public static func requestDigest(for canonicalBytes: Data) -> ObjectID {
        ObjectID(data: canonicalBytes)
    }

    public static func isCanonical(_ data: Data) -> Bool {
        (try? decodeCanonical(data)) != nil
    }

    private init(
        commandId: UUID,
        commandKind: String,
        sourceGeneration: Int64,
        sourceSnapshotId: SnapshotID,
        binding: Binding,
        payloadBytes: Data,
        canonicalBytes: Data,
        requestDigest: ObjectID
    ) {
        self.commandId = commandId
        self.commandKind = commandKind
        self.sourceGeneration = sourceGeneration
        self.sourceSnapshotId = sourceSnapshotId
        self.binding = binding
        self.payloadBytes = payloadBytes
        self.canonicalBytes = canonicalBytes
        self.requestDigest = requestDigest
    }
}

private extension CanonicalJSON.Value {
    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}
