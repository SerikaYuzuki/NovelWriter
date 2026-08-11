import CloudKit
import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit whole-work record codec")
struct CloudKitWorkRecordCodecTests {
    @Test("control, revision asset, and receipt round-trip exact work metadata")
    func wholeWorkRecordsRoundTrip() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let revision = try makeWorkRevision()
        let mutationID = try SyncMutationID(
            rawValue: #require(UUID(uuidString: "77777777-7777-4777-8777-777777777777"))
        )

        let emptyControl = codec.makeEmptyWorkControlRecord(for: cloudTestWorkID)
        let decodedEmpty = try codec.decodeWorkControlRecord(
            emptyControl,
            expectedWorkID: cloudTestWorkID
        )
        #expect(decodedEmpty.headRevisionID == nil)
        #expect(decodedEmpty.headSnapshotDigest == nil)

        let control = try codec.updateWorkControlRecord(
            emptyControl,
            workID: cloudTestWorkID,
            headRevisionID: revision.revisionID,
            headSnapshotDigest: revision.snapshotDigest,
            libraryEntry: SyncWorkLibraryEntry(head: revision)
        )
        let decodedControl = try codec.decodeWorkControlRecord(
            control,
            expectedWorkID: cloudTestWorkID
        )
        #expect(decodedControl.headRevisionID == revision.revisionID)
        #expect(decodedControl.headSnapshotDigest == revision.snapshotDigest)
        #expect(try decodedControl.libraryEntry == SyncWorkLibraryEntry(head: revision))

        let encoded = try codec.makeWorkRevisionRecord(revision, mutationID: mutationID)
        defer { codec.removeStagedAssets([encoded.stagedAsset]) }
        #expect(encoded.record[CloudKitSyncSchema.Field.bodyAsset] == nil)
        #expect(encoded.record[CloudKitSyncSchema.Field.revisionAsset] is CKAsset)
        #expect(encoded.record[CloudKitSyncSchema.Field.attachmentCount] as? Int64 == 0)
        #expect(
            try codec.decodeWorkRevisionRecord(
                encoded.record,
                expectedWorkID: cloudTestWorkID,
                expectedRevisionID: revision.revisionID
            ) == revision
        )

        let receipt = CloudKitWorkMutationReceipt(
            workID: cloudTestWorkID,
            mutationID: mutationID,
            commandDigest: SyncContentDigest(content: "work-command"),
            resultHeadRevisionID: revision.revisionID,
            resultHeadSnapshotDigest: revision.snapshotDigest
        )
        let receiptRecord = codec.makeWorkMutationReceiptRecord(receipt)
        #expect(
            try codec.decodeWorkMutationReceipt(
                receiptRecord,
                expectedWorkID: cloudTestWorkID,
                expectedMutationID: mutationID
            ) == receipt
        )
    }

    @Test("revision asset tampering and unsupported attachment metadata are rejected")
    func assetAndResourceTamperingAreRejected() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let revision = try makeWorkRevision()
        let encoded = try codec.makeWorkRevisionRecord(revision, mutationID: SyncMutationID())
        defer { codec.removeStagedAssets([encoded.stagedAsset]) }

        encoded.record[CloudKitSyncSchema.Field.attachmentCount] = NSNumber(value: 1)
        encoded.record[CloudKitSyncSchema.Field.attachmentManifestDigest] = SyncContentDigest(
            content: "manifest"
        ).rawValue as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.decodeWorkRevisionRecord(
                encoded.record,
                expectedWorkID: cloudTestWorkID,
                expectedRevisionID: revision.revisionID
            )
        }

        encoded.record[CloudKitSyncSchema.Field.attachmentCount] = NSNumber(value: 0)
        encoded.record[CloudKitSyncSchema.Field.attachmentManifestDigest] = nil
        try Data("{}".utf8).write(to: encoded.stagedAsset.url, options: .atomic)
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteAsset) {
            try codec.decodeWorkRevisionRecord(
                encoded.record,
                expectedWorkID: cloudTestWorkID,
                expectedRevisionID: revision.revisionID
            )
        }
    }

    @Test("control requires an exact head ID and snapshot digest pair")
    func controlRejectsHalfHeadIdentity() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let record = codec.makeEmptyWorkControlRecord(for: cloudTestWorkID)
        record[CloudKitSyncSchema.Field.headRevisionID] = UUID().uuidString as CKRecordValue

        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.decodeWorkControlRecord(record, expectedWorkID: cloudTestWorkID)
        }
    }
}

func makeCloudTestWorkSnapshot(title: String = "地下鉄で書いた作品") throws -> WorkSnapshot {
    let document = NovelDocument(
        id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
        title: title,
        synopsis: "通信が戻ったら統合します。",
        chapters: [
            Chapter(
                id: ChapterID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!),
                title: "第一章",
                episodes: [
                    Episode(
                        id: EpisodeID(
                            rawValue: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
                        ),
                        title: "本文",
                        content: "　本文です。\n「続き」",
                        memo: "話メモ"
                    )
                ]
            )
        ]
    )
    return try WorkSnapshot(document: document)
}

func makeWorkRevision(
    id: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
    parents: [SyncRevisionID] = [],
    title: String = "地下鉄で書いた作品",
    workID: SyncWorkID = cloudTestWorkID
) throws -> WorkRevision {
    try WorkRevision(
        workID: workID,
        revisionID: SyncRevisionID(rawValue: id),
        parentRevisionIDs: parents,
        branchID: cloudTestBranchID,
        authorReplicaID: cloudTestReplicaID,
        authorSessionID: cloudTestSessionID,
        snapshot: makeCloudTestWorkSnapshot(title: title),
        clientCreatedAt: cloudTestDate
    )
}
