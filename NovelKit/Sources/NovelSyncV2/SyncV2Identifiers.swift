import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum SyncV2UUID {
    static func parse(_ string: String) -> UUID? {
        guard string.count == 36,
              let value = UUID(uuidString: string),
              value.uuidString.lowercased() == string else {
            return nil
        }
        return value
    }
}

public struct WorkID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let value = SyncV2UUID.parse(uuidString) else {
            throw SyncV2TypeError.invalidUUID
        }
        rawValue = value
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        try self.init(
            uuidString: decoder.singleValueContainer().decode(String.self)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct DocumentID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(uuidString: String) throws {
        guard let value = SyncV2UUID.parse(uuidString) else {
            throw SyncV2TypeError.invalidUUID
        }
        rawValue = value
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        try self.init(
            uuidString: decoder.singleValueContainer().decode(String.self)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct ObjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 48 && scalar.value <= 57 || scalar.value >= 97 && scalar.value <= 102
              }) else {
            throw SyncV2TypeError.invalidDigest
        }
        self.rawValue = rawValue
    }

    public init(data: Data) {
        rawValue = SHA256Digest.hex(data)
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(
            rawValue: decoder.singleValueContainer().decode(String.self)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SnapshotID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 48 && scalar.value <= 57 || scalar.value >= 97 && scalar.value <= 102
              }) else {
            throw SyncV2TypeError.invalidDigest
        }
        self.rawValue = rawValue
    }

    public init(data: Data) {
        rawValue = SHA256Digest.hex(data)
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(
            rawValue: decoder.singleValueContainer().decode(String.self)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SHA256Digest {
    #if canImport(CryptoKit)
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
    #else
    @available(*, unavailable, message: "Snapshot Sync v2 requires CryptoKit for SHA-256")
    public static func hex(_: Data) -> String {
        fatalError("CryptoKit unavailable")
    }
    #endif
}
