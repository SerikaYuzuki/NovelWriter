import Foundation
import NovelCore
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum SyncV2TypeError: Error, Equatable, Sendable {
    case invalidUUID
    case invalidDigest
    case invalidManifest
    case invalidEntityKey
    case missingEntity(String)
    case duplicateEntity(String)
    case schemaViolation(String)
    case digestMismatch
    case byteCountMismatch
    case unsupportedContentType
    case referenceViolation(String)
    case commandViolation(String)
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
        guard let value = UUID(uuidString: uuidString.lowercased()), value.uuidString.lowercased() == uuidString else {
            throw SyncV2TypeError.invalidUUID
        }
        rawValue = value
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        try self.init(uuidString: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(description)
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
        guard let value = UUID(uuidString: uuidString.lowercased()), value.uuidString.lowercased() == uuidString else { throw SyncV2TypeError.invalidUUID }
        rawValue = value
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        try self.init(uuidString: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(description)
    }
}

public struct ObjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) throws {
        guard rawValue.count == 64, rawValue.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 || $0.value >= 97 && $0.value <= 102 }) else { throw SyncV2TypeError.invalidDigest }
        self.rawValue = rawValue
    }

    public init(data: Data) {
        rawValue = SHA256Digest.hex(data)
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct SnapshotID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) throws {
        guard rawValue.count == 64, rawValue.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 || $0.value >= 97 && $0.value <= 102 }) else { throw SyncV2TypeError.invalidDigest }
        self.rawValue = rawValue
    }

    public init(data: Data) {
        rawValue = SHA256Digest.hex(data)
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public enum SHA256Digest {
    public static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return data.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

public struct SnapshotEntry: Codable, Hashable, Sendable {
    public enum ContentType: String, Codable, Sendable { case entityJSON = "application/vnd.fuminiwa.entity+json;version=2"; case octetStream = "application/octet-stream" }
    public let byteCount: Int
    public let contentType: ContentType
    public let entityKey: String
    public let objectId: ObjectID
    public init(byteCount: Int, contentType: ContentType, entityKey: String, objectId: ObjectID) {
        self.byteCount = byteCount; self.contentType = contentType; self.entityKey = entityKey; self.objectId = objectId
    }
}

public struct SnapshotManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let workId: WorkID
    public let parentSnapshotIds: [SnapshotID]
    public let entries: [SnapshotEntry]
    public init(workId: WorkID, parentSnapshotIds: [SnapshotID] = [], entries: [SnapshotEntry]) {
        schemaVersion = 2; self.workId = workId; self.parentSnapshotIds = parentSnapshotIds; self.entries = entries
    }
}

public struct SyncAttachment: Hashable, Sendable {
    public let attachmentId: UUID
    public let fileName: String
    public let byteCount: Int
    public let bytes: Data
    public var objectId: ObjectID {
        ObjectID(data: bytes)
    }

    public init(attachmentId: UUID, fileName: String, bytes: Data) {
        self.attachmentId = attachmentId; self.fileName = fileName; self.bytes = bytes; byteCount = bytes.count
    }
}

public struct SnapshotModel: Sendable {
    public let workId: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]
    public init(workId: WorkID, document: NovelDocument, documentCreatedAt: Date, attachments: [SyncAttachment] = []) {
        self.workId = workId; self.document = document; self.documentCreatedAt = documentCreatedAt; self.attachments = attachments
    }
}

public struct EncodedSnapshot: Sendable {
    public let manifest: SnapshotManifest
    public let manifestBytes: Data
    public let objects: [ObjectID: Data]
    public var snapshotId: SnapshotID {
        SnapshotID(data: manifestBytes)
    }

    public init(manifest: SnapshotManifest, manifestBytes: Data, objects: [ObjectID: Data]) {
        self.manifest = manifest; self.manifestBytes = manifestBytes; self.objects = objects
    }
}
