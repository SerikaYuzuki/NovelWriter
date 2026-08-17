import Foundation
import NovelCore

public struct SnapshotEntry: Codable, Hashable, Sendable {
    public enum ContentType: String, Codable, Sendable {
        case entityJSON = "application/vnd.fuminiwa.entity+json;version=2"
        case octetStream = "application/octet-stream"
    }

    public let byteCount: Int
    public let contentType: ContentType
    public let entityKey: String
    public let objectId: ObjectID

    public init(
        byteCount: Int,
        contentType: ContentType,
        entityKey: String,
        objectId: ObjectID
    ) {
        self.byteCount = byteCount
        self.contentType = contentType
        self.entityKey = entityKey
        self.objectId = objectId
    }
}

public struct SnapshotManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let workId: WorkID
    public let parentSnapshotIds: [SnapshotID]
    public let entries: [SnapshotEntry]

    public init(
        workId: WorkID,
        parentSnapshotIds: [SnapshotID] = [],
        entries: [SnapshotEntry]
    ) {
        schemaVersion = 2
        self.workId = workId
        self.parentSnapshotIds = parentSnapshotIds
        self.entries = entries
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
        self.attachmentId = attachmentId
        self.fileName = fileName
        self.bytes = bytes
        byteCount = bytes.count
    }
}

public struct SnapshotModel: Sendable {
    public let workId: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]

    public init(
        workId: WorkID,
        document: NovelDocument,
        documentCreatedAt: Date,
        attachments: [SyncAttachment] = []
    ) {
        self.workId = workId
        self.document = document
        self.documentCreatedAt = documentCreatedAt
        self.attachments = attachments
    }
}

public struct EncodedSnapshot: Sendable {
    public let manifest: SnapshotManifest
    public let manifestBytes: Data
    public let objects: [ObjectID: Data]

    public var snapshotId: SnapshotID {
        SnapshotID(data: manifestBytes)
    }

    public init(
        manifest: SnapshotManifest,
        manifestBytes: Data,
        objects: [ObjectID: Data]
    ) {
        self.manifest = manifest
        self.manifestBytes = manifestBytes
        self.objects = objects
    }
}
