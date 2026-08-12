import CloudKit
import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit work-library listing")
struct CloudKitWorkLibraryRecordDecoderTests {
    @Test("nil-head controls are hidden while complete heads list exact projection")
    func hidesNilHeadAndListsCompleteHead() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let initialSnapshot = try makeCloudTestWorkSnapshot()
        let descriptor = try SyncWorkDescriptor(
            workID: cloudTestWorkID,
            sourceDocumentID: initialSnapshot.documentID.rawValue,
            structureDigest: SyncWorkStructureDigest(
                chapters: initialSnapshot.materializedDocument().chapters
            ),
            title: "作成直後"
        )
        let nilHead = try codec.makeInitialWorkControlRecord(descriptor)
        let revision = try makeWorkRevision()
        let entry = try SyncWorkLibraryEntry(head: revision)
        let complete = try codec.updateWorkControlRecord(
            nil,
            workID: revision.workID,
            headRevisionID: revision.revisionID,
            headSnapshotDigest: revision.snapshotDigest,
            libraryEntry: entry
        )
        let decoder = CloudKitWorkLibraryRecordDecoder(codec: codec)

        #expect(try decoder.decode([nilHead]).isEmpty)
        #expect(try decoder.decode([complete]) == [entry])
    }

    @Test("partial projection, duplicate work IDs, and head without projection fail closed")
    func rejectsMalformedAndDuplicateControls() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let revision = try makeWorkRevision()
        let entry = try SyncWorkLibraryEntry(head: revision)
        let complete = try codec.updateWorkControlRecord(
            nil,
            workID: revision.workID,
            headRevisionID: revision.revisionID,
            headSnapshotDigest: revision.snapshotDigest,
            libraryEntry: entry
        )
        let decoder = CloudKitWorkLibraryRecordDecoder(codec: codec)

        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try decoder.decode([complete, complete])
        }
        let partial = try codec.updateWorkControlRecord(
            nil,
            workID: revision.workID,
            headRevisionID: revision.revisionID,
            headSnapshotDigest: revision.snapshotDigest,
            libraryEntry: entry
        )
        partial[CloudKitSyncSchema.Field.titleDigest] = nil
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try decoder.decode([partial])
        }
        let noProjection = codec.makeEmptyWorkControlRecord(for: revision.workID)
        noProjection[CloudKitSyncSchema.Field.headRevisionID] = revision.revisionID
            .rawValue.uuidString as CKRecordValue
        noProjection[CloudKitSyncSchema.Field.snapshotDigest] = revision.snapshotDigest
            .rawValue as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try decoder.decode([noProjection])
        }
    }

    @Test("malformed workだけを隔離して他のcatalog行を残す")
    func isolatesMalformedControlWithoutHidingValidWork() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let first = try makeWorkRevision()
        let secondWorkID = try SyncWorkID(rawValue: #require(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")
        ))
        let second = try makeWorkRevision(
            id: #require(UUID(uuidString: "88888888-8888-4888-8888-888888888888")),
            title: "残る作品",
            workID: secondWorkID
        )
        let firstEntry = try SyncWorkLibraryEntry(head: first)
        let secondEntry = try SyncWorkLibraryEntry(head: second)
        let malformed = try codec.updateWorkControlRecord(
            nil,
            workID: first.workID,
            headRevisionID: first.revisionID,
            headSnapshotDigest: first.snapshotDigest,
            libraryEntry: firstEntry
        )
        malformed[CloudKitSyncSchema.Field.titleDigest] = nil
        let valid = try codec.updateWorkControlRecord(
            nil,
            workID: second.workID,
            headRevisionID: second.revisionID,
            headSnapshotDigest: second.snapshotDigest,
            libraryEntry: secondEntry
        )
        let decoder = CloudKitWorkLibraryRecordDecoder(codec: codec)

        #expect(decoder.decodeIsolatingMalformed([malformed, valid]) == [secondEntry])
        #expect(decoder.decodeIsolatingMalformed([valid, valid]).isEmpty)
    }
}
