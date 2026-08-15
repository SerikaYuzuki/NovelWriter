import CloudKit
import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit record codec")
struct CloudKitRecordCodecTests {
    @Test("record names are versioned, deterministic, and scoped by opaque work and episode IDs")
    func recordNamesAreOpaqueAndScoped() throws {
        let control = CloudKitSyncRecordNames.episodeControl(cloudTestKey)
        let revisionID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        )
        let revision = CloudKitSyncRecordNames.revision(revisionID, key: cloudTestKey)

        #expect(control == "v1.work.4D875891-E4A9-45CC-B0E3-9CB9024EAA18.episode.635158B4-E377-4D24-9338-9691442CFF94.control")
        #expect(revision.contains(cloudTestWorkID.rawValue.uuidString))
        #expect(revision.contains(cloudTestEpisodeID.rawValue.uuidString))
        #expect(!revision.contains("作品"))
        #expect(CKRecord.ID.episodeControl(cloudTestKey).zoneID == CloudKitSyncSchema.zoneID)
        #expect(CloudKitSyncSchema.zoneName == "FUMINIWA.DeviceSync.v1")
    }

    @Test("work and leased control round-trip without using titles in record identity")
    func workAndControlRoundTrip() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let sourceID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let structureDigest = try SyncWorkStructureDigest(
            validating: String(repeating: "a", count: 64)
        )
        let descriptor = SyncWorkDescriptor(
            workID: cloudTestWorkID,
            sourceDocumentID: sourceID,
            structureDigest: structureDigest,
            title: "秘密の作品名"
        )
        let workRecord = try codec.makeWorkRecord(descriptor)
        #expect(workRecord.recordID.recordName == CloudKitSyncRecordNames.work(cloudTestWorkID))
        #expect(!workRecord.recordID.recordName.contains(descriptor.title))
        #expect(
            workRecord[CloudKitSyncSchema.Field.structureDigest] as? String
                == structureDigest.rawValue
        )
        #expect(try codec.decodeWorkRecord(workRecord) == descriptor)

        workRecord[CloudKitSyncSchema.Field.structureDigest] = "invalid" as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.decodeWorkRecord(workRecord)
        }
        workRecord[CloudKitSyncSchema.Field.structureDigest] = structureDigest.rawValue as CKRecordValue

        let headID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )
        let lease = try makeCloudTestLease()
        let controlRecord = try codec.updateControlRecord(
            nil,
            key: cloudTestKey,
            headRevisionID: headID,
            leaseEpoch: lease.authority.epoch,
            lease: lease
        )
        let decoded = try codec.decodeControlRecord(controlRecord, expectedKey: cloudTestKey)
        #expect(decoded.headRevisionID == headID)
        #expect(decoded.leaseEpoch == 12)
        #expect(decoded.lease == lease)
    }

    @Test("revision body is exact canonical UTF-8 and staged asset is removable")
    func revisionAssetRoundTripAndCleanup() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let revisionID = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let content = "　本文です。\r\n「続き」👩‍💻e\u{301}\n"
        let revision = try makeCloudTestRevision(id: revisionID, parents: [], content: content)
        let mutationID = try SyncMutationID(
            rawValue: #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        )
        let encoded = try codec.makeRevisionRecord(revision, mutationID: mutationID)
        #expect(FileManager.default.fileExists(atPath: encoded.stagedAsset.url.path))
        #expect(encoded.record[CloudKitSyncSchema.Field.parentRevisionIDs] == nil)

        let decoded = try codec.decodeRevisionRecord(
            encoded.record,
            expectedKey: cloudTestKey,
            expectedRevisionID: revision.revisionID
        )
        #expect(decoded == revision)
        #expect(Array(decoded.content.utf8) == Array(content.utf8))

        codec.removeStagedAssets([encoded.stagedAsset])
        #expect(!FileManager.default.fileExists(atPath: encoded.stagedAsset.url.path))
    }

    @Test("asset tampering and digest mismatch are rejected")
    func assetTamperingIsRejected() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let revision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555")),
            parents: [],
            content: "本文"
        )
        let encoded = try codec.makeRevisionRecord(revision, mutationID: SyncMutationID())
        defer { codec.removeStagedAssets([encoded.stagedAsset]) }
        try Data("改竄".utf8).write(to: encoded.stagedAsset.url, options: .atomic)

        #expect(throws: CloudKitSyncAdapterError.invalidRemoteAsset) {
            try codec.decodeRevisionRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: revision.revisionID
            )
        }
    }

    @Test("metadata rejects Bool numbers, malformed mutation IDs, and invalid parent sets")
    func metadataTypeAndParentValidation() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let revision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666")),
            parents: [],
            content: "本文"
        )
        let encoded = try codec.makeRevisionRecord(revision, mutationID: SyncMutationID())
        defer { codec.removeStagedAssets([encoded.stagedAsset]) }

        encoded.record[CloudKitSyncSchema.Field.bodyByteCount] = true as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.validateRevisionMetadataRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: revision.revisionID
            )
        }

        encoded.record[CloudKitSyncSchema.Field.bodyByteCount] = NSNumber(value: revision.content.utf8.count)
        encoded.record[CloudKitSyncSchema.Field.mutationID] = "lowercase-not-a-uuid" as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.validateRevisionMetadataRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: revision.revisionID
            )
        }

        encoded.record[CloudKitSyncSchema.Field.mutationID] = UUID().uuidString as CKRecordValue
        encoded.record[CloudKitSyncSchema.Field.parentRevisionIDs] = [
            UUID().uuidString,
            UUID().uuidString,
            UUID().uuidString
        ] as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.validateRevisionMetadataRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: revision.revisionID
            )
        }

        let duplicateParent = UUID().uuidString
        encoded.record[CloudKitSyncSchema.Field.parentRevisionIDs] = [
            duplicateParent,
            duplicateParent
        ] as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.validateRevisionMetadataRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: revision.revisionID
            )
        }
    }

    @Test("control rejects Bool masquerading as an integer epoch")
    func controlRejectsBooleanEpoch() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let control = codec.makeEmptyControlRecord(for: cloudTestKey)
        control[CloudKitSyncSchema.Field.leaseEpoch] = true as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.decodeControlRecord(control, expectedKey: cloudTestKey)
        }
    }

    @Test("mutation receipt round-trips the acknowledged head and lease")
    func mutationReceiptRoundTrip() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let mutationID = try SyncMutationID(
            rawValue: #require(UUID(uuidString: "77777777-7777-4777-8777-777777777777"))
        )
        let headID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "88888888-8888-4888-8888-888888888888"))
        )
        let receipt = try CloudKitMutationReceipt(
            key: cloudTestKey,
            mutationID: mutationID,
            commandDigest: SyncContentDigest(content: "command"),
            resultHeadRevisionID: headID,
            resultLease: makeCloudTestLease()
        )
        let record = codec.makeMutationReceiptRecord(receipt)
        #expect(
            try codec.decodeMutationReceipt(
                record,
                expectedKey: cloudTestKey,
                expectedMutationID: mutationID
            ) == receipt
        )
    }

    @Test("filesystem root itself cannot be used as an asset staging directory")
    func rootAssetDirectoryIsRejected() {
        #expect(throws: CloudKitSyncAdapterError.unsafeAssetRoot) {
            try CloudKitAssetStore(rootURL: URL(fileURLWithPath: "/", isDirectory: true))
        }
    }

    @Test("restart removes only stale staged assets and never follows unknown links")
    func restartSweepsStaleAssetSession() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let first = try CloudKitAssetStore(rootURL: root, sessionID: UUID())
        let staged = try first.stage(content: "終了直前の本文")
        let firstSessionRoot = first.rootURL
        let unknown = root.appendingPathComponent("利用者の未知ファイル.txt")
        try Data("keep".utf8).write(to: unknown)
        let external = root.deletingLastPathComponent().appendingPathComponent("asset-sweep-external-(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("outside".utf8).write(to: external)
        let link = root.appendingPathComponent("session-(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        let restarted = try CloudKitAssetStore(rootURL: root, sessionID: UUID())

        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
        #expect(!FileManager.default.fileExists(atPath: firstSessionRoot.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: external.path))
        let fresh = try restarted.stage(content: "再起動後の本文")
        #expect(FileManager.default.fileExists(atPath: fresh.url.path))
        restarted.remove([fresh])
    }
}

@Suite("CloudKit revision parent list codec")
struct CloudKitRevisionParentListTests {
    @Test("root omits an empty parent list and child requires a non-empty string list")
    func parentListEncodingMatchesCloudKitContract() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let parentID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "41414141-4141-4141-8141-414141414141"))
        )
        let child = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "42424242-4242-4242-8242-424242424242")),
            parents: [parentID],
            content: "親の続き"
        )
        let encoded = try codec.makeRevisionRecord(child, mutationID: SyncMutationID())
        defer { codec.removeStagedAssets([encoded.stagedAsset]) }

        #expect(
            encoded.record[CloudKitSyncSchema.Field.parentRevisionIDs] as? [String]
                == [parentID.rawValue.uuidString]
        )
        #expect(
            try codec.decodeRevisionRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: child.revisionID
            ).parentRevisionIDs == [parentID]
        )

        encoded.record[CloudKitSyncSchema.Field.parentRevisionIDs] = [String]() as CKRecordValue
        #expect(throws: CloudKitSyncAdapterError.invalidRemoteRecord) {
            try codec.validateRevisionMetadataRecord(
                encoded.record,
                expectedKey: cloudTestKey,
                expectedRevisionID: child.revisionID
            )
        }
    }
}
