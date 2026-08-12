import Foundation

public enum SyncWorkLibraryError: Error, Equatable, Sendable {
    case inconsistentHeadIdentity
    case workMismatch
    case snapshotMismatch
    case titleTooLarge
}

/// 作品棚で使う軽量なremote truth。
///
/// `headClientCreatedAt`は表示用であり、競合解決やwinner選択には使わない。
/// headのID／digest／byte countを一組で持つため、作品を開く際は取得した
/// `WorkRevision`がこの値とexact一致することを検査できる。
public struct SyncWorkLibraryEntry: Hashable, Codable, Sendable, Identifiable {
    public static let maximumDisplayTitleUTF8Bytes = 1024

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case workID
        case sourceDocumentID
        case structureDigest
        case title
        case titleDigest
        case fullTitleUTF8ByteCount
        case headRevisionID
        case headSnapshotDigest
        case headSnapshotByteCount
        case headClientCreatedAt
    }

    public var id: SyncWorkID {
        workID
    }

    public let workID: SyncWorkID
    public let sourceDocumentID: UUID
    public let structureDigest: SyncWorkStructureDigest
    /// Bounded display projection. Exact full-title identity is `titleDigest`.
    public let title: String
    public let titleDigest: SyncContentDigest
    public let fullTitleUTF8ByteCount: Int
    public let headRevisionID: SyncRevisionID?
    public let headSnapshotDigest: SyncContentDigest?
    public let headSnapshotByteCount: Int?
    public let headClientCreatedAt: Date?

    public var isTitleTruncated: Bool {
        fullTitleUTF8ByteCount > title.utf8.count
    }

    public init(
        workID: SyncWorkID,
        sourceDocumentID: UUID,
        structureDigest: SyncWorkStructureDigest,
        title: String,
        titleDigest: SyncContentDigest,
        fullTitleUTF8ByteCount: Int,
        headRevisionID: SyncRevisionID?,
        headSnapshotDigest: SyncContentDigest?,
        headSnapshotByteCount: Int?,
        headClientCreatedAt: Date?
    ) throws {
        self.workID = workID
        self.sourceDocumentID = sourceDocumentID
        self.structureDigest = structureDigest
        self.title = title
        self.titleDigest = titleDigest
        self.fullTitleUTF8ByteCount = fullTitleUTF8ByteCount
        self.headRevisionID = headRevisionID
        self.headSnapshotDigest = headSnapshotDigest
        self.headSnapshotByteCount = headSnapshotByteCount
        self.headClientCreatedAt = headClientCreatedAt.map(normalizedSyncTimestamp)
        try validate()
    }

    public init(descriptor: SyncWorkDescriptor) throws {
        try self.init(
            workID: descriptor.workID,
            sourceDocumentID: descriptor.sourceDocumentID,
            structureDigest: descriptor.structureDigest,
            title: Self.displayTitleProjection(descriptor.title),
            titleDigest: SyncContentDigest(content: descriptor.title),
            fullTitleUTF8ByteCount: descriptor.title.utf8.count,
            headRevisionID: nil,
            headSnapshotDigest: nil,
            headSnapshotByteCount: nil,
            headClientCreatedAt: nil
        )
    }

    public init(head revision: WorkRevision) throws {
        try revision.validate()
        let document = try revision.snapshot.materializedDocument()
        try self.init(
            workID: revision.workID,
            sourceDocumentID: document.id,
            structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
            title: Self.displayTitleProjection(document.title),
            titleDigest: SyncContentDigest(content: document.title),
            fullTitleUTF8ByteCount: document.title.utf8.count,
            headRevisionID: revision.revisionID,
            headSnapshotDigest: revision.snapshotDigest,
            headSnapshotByteCount: revision.snapshotByteCount,
            headClientCreatedAt: revision.clientCreatedAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentWorkSyncWireVersion(forKey: .protocolVersion, in: container)
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        sourceDocumentID = try decodeCanonicalSyncUUID(forKey: .sourceDocumentID, in: container)
        structureDigest = try container.decode(
            SyncWorkStructureDigest.self,
            forKey: .structureDigest
        )
        title = try container.decode(String.self, forKey: .title)
        titleDigest = try container.decode(SyncContentDigest.self, forKey: .titleDigest)
        fullTitleUTF8ByteCount = try container.decode(
            Int.self,
            forKey: .fullTitleUTF8ByteCount
        )
        headRevisionID = try container.decodeIfPresent(
            SyncRevisionID.self,
            forKey: .headRevisionID
        )
        headSnapshotDigest = try container.decodeIfPresent(
            SyncContentDigest.self,
            forKey: .headSnapshotDigest
        )
        headSnapshotByteCount = try container.decodeIfPresent(
            Int.self,
            forKey: .headSnapshotByteCount
        )
        headClientCreatedAt = try container.contains(.headClientCreatedAt)
            ? decodeCanonicalSyncTimestamp(forKey: .headClientCreatedAt, in: container)
            : nil
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WorkSyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(workID, forKey: .workID)
        try container.encode(sourceDocumentID.uuidString, forKey: .sourceDocumentID)
        try container.encode(structureDigest, forKey: .structureDigest)
        try container.encode(title, forKey: .title)
        try container.encode(titleDigest, forKey: .titleDigest)
        try container.encode(fullTitleUTF8ByteCount, forKey: .fullTitleUTF8ByteCount)
        try container.encodeIfPresent(headRevisionID, forKey: .headRevisionID)
        try container.encodeIfPresent(headSnapshotDigest, forKey: .headSnapshotDigest)
        try container.encodeIfPresent(headSnapshotByteCount, forKey: .headSnapshotByteCount)
        if let headClientCreatedAt {
            try encodeCanonicalSyncTimestamp(
                headClientCreatedAt,
                forKey: .headClientCreatedAt,
                in: &container
            )
        }
    }

    public func validate() throws {
        let headValuesPresent = [
            headRevisionID != nil,
            headSnapshotDigest != nil,
            headSnapshotByteCount != nil,
            headClientCreatedAt != nil
        ]
        guard headValuesPresent.allSatisfy(\.self) || headValuesPresent.allSatisfy({ !$0 }) else {
            throw SyncWorkLibraryError.inconsistentHeadIdentity
        }
        guard title.utf8.count <= Self.maximumDisplayTitleUTF8Bytes,
              fullTitleUTF8ByteCount >= title.utf8.count,
              fullTitleUTF8ByteCount <= WorkSnapshot.maximumStringUTF8Bytes else {
            throw SyncWorkLibraryError.titleTooLarge
        }
        if fullTitleUTF8ByteCount <= Self.maximumDisplayTitleUTF8Bytes {
            guard fullTitleUTF8ByteCount == title.utf8.count,
                  titleDigest == SyncContentDigest(content: title) else {
                throw SyncWorkLibraryError.inconsistentHeadIdentity
            }
        }
        if let byteCount = headSnapshotByteCount {
            guard byteCount >= 0, byteCount <= WorkSnapshot.maximumCanonicalByteCount else {
                throw SyncWorkLibraryError.inconsistentHeadIdentity
            }
        }
    }

    public func requireExactHead(_ revision: WorkRevision) throws {
        try revision.validate()
        guard revision.workID == workID else {
            throw SyncWorkLibraryError.workMismatch
        }
        guard revision.revisionID == headRevisionID,
              revision.snapshotDigest == headSnapshotDigest,
              revision.snapshotByteCount == headSnapshotByteCount,
              revision.clientCreatedAt == headClientCreatedAt else {
            throw SyncWorkLibraryError.snapshotMismatch
        }
        guard try Self(head: revision) == self else {
            throw SyncWorkLibraryError.snapshotMismatch
        }
    }

    public static func displayTitleProjection(_ fullTitle: String) -> String {
        guard fullTitle.utf8.count > maximumDisplayTitleUTF8Bytes else {
            return fullTitle
        }
        var projection = ""
        projection.reserveCapacity(maximumDisplayTitleUTF8Bytes)
        var usedBytes = 0
        for scalar in fullTitle.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard usedBytes + scalarByteCount <= maximumDisplayTitleUTF8Bytes else {
                break
            }
            projection.unicodeScalars.append(scalar)
            usedBytes += scalarByteCount
        }
        return projection
    }
}

/// Remote assetをdownloadせず、作品棚に必要な最新head metadataだけを列挙する。
public protocol SyncWorkLibraryCatalog: Sendable {
    func listLibraryWorks() async throws -> [SyncWorkLibraryEntry]
}
