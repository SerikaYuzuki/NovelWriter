import Foundation

/// Read-only projection of the already validated command payload; never used to encode wire bytes.
public struct SyncV2CommandPayload: Hashable, Sendable {
    public struct Head: Hashable, Sendable {
        public let snapshotID: SnapshotID
        public let generation: Int64
    }

    private let strings: [String: String]
    private let integers: [String: Int64]
    private let heads: [String: Head]
    private let nulls: Set<String>

    init(_ value: CanonicalJSON.Value) throws {
        guard case let .object(pairs) = value else {
            throw SyncV2TypeError.commandViolation("payload")
        }
        var strings: [String: String] = [:]
        var integers: [String: Int64] = [:]
        var heads: [String: Head] = [:]
        var nulls: Set<String> = []
        for (key, value) in pairs {
            switch value {
            case let .string(value): strings[key] = value
            case let .number(value): integers[key] = value
            case .null: nulls.insert(key)
            case let .object(fields):
                let fields = Dictionary(fields, uniquingKeysWith: { first, _ in first })
                if case let .string(snapshot) = fields["snapshotId"],
                   case let .number(generation) = fields["generation"] {
                    heads[key] = try Head(snapshotID: SnapshotID(rawValue: snapshot), generation: generation)
                }
            default: break
            }
        }
        self.strings = strings
        self.integers = integers
        self.heads = heads
        self.nulls = nulls
    }

    public func string(_ key: String) -> String? {
        strings[key]
    }

    public func integer(_ key: String) -> Int64? {
        integers[key]
    }

    public func uuid(_ key: String) throws -> String {
        guard let value = strings[key], let parsed = UUID(uuidString: value),
              parsed.uuidString.lowercased() == value else {
            throw SyncV2TypeError.commandViolation(key)
        }
        return value
    }

    public func snapshot(_ key: String) throws -> SnapshotID {
        guard let value = strings[key] else { throw SyncV2TypeError.commandViolation(key) }
        return try SnapshotID(rawValue: value)
    }

    public func object(_ key: String) throws -> ObjectID {
        guard let value = strings[key] else { throw SyncV2TypeError.commandViolation(key) }
        return try ObjectID(rawValue: value)
    }

    public func head(_ key: String) throws -> Head? {
        if nulls.contains(key) {
            return nil
        }
        guard let value = heads[key] else { throw SyncV2TypeError.commandViolation(key) }
        return value
    }

    public var workID: WorkID {
        get throws {
            guard let value = strings["workId"] ?? strings["sourceWorkId"] else {
                throw SyncV2TypeError.commandViolation("workId")
            }
            return try WorkID(uuidString: value)
        }
    }
}
