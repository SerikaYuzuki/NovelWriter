import CloudKit
import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit note entity codec")
struct CloudKitNoteRecordCodecTests {
    @Test("note work and episode round-trip inline JSON without whole-work assets")
    func inlineNoteRecordsRoundTrip() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let work = try NoteSyncRecord(
            key: .work(cloudTestWorkID),
            payload: .work(
                NoteSyncWorkPayload(
                    documentID: WorkStableID(rawValue: cloudTestWorkID.rawValue),
                    title: "銀河鉄道",
                    synopsis: "あらすじ",
                    chapterOrder: [WorkStableID(rawValue: cloudTestEpisodeID.rawValue)],
                    characterOrder: [],
                    plotCardOrder: [],
                    flagOrder: [],
                    worldNoteOrder: []
                )
            )
        )
        let encoded = try codec.makeNoteRecord(work)
        #expect(encoded.stagedAsset == nil)
        #expect(encoded.record.recordType == CloudKitSyncSchema.RecordType.noteWork)
        #expect(encoded.record.recordID.recordName.hasPrefix("v1.note."))
        let schema = try #require(
            CloudKitSyncSchema.noteSyncProductionSchemaChecklist.first {
                $0.name == encoded.record.recordType
            }
        )
        let keys = Set(encoded.record.allKeys())
        #expect(schema.requiredFields.isSubset(of: keys))
        #expect(keys.isSubset(of: Set(schema.fields.keys)))
        #expect(schema.queryableFields.contains(CloudKitSyncSchema.Field.workID))
        #expect(
            CloudKitSyncSchema.noteSyncProductionSchemaChecklist.allSatisfy {
                $0.queryableFields == [CloudKitSyncSchema.Field.workID]
            }
        )
    }

    @Test("large episode payload stages a per-entity asset instead of a whole-work asset")
    func largeEpisodePayloadUsesEntityAsset() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let content = String(repeating: "あ", count: 280_000)
        let episode = try NoteSyncRecord(
            key: NoteSyncEntityKey(
                workID: cloudTestWorkID,
                kind: .episode,
                entityID: WorkStableID(rawValue: cloudTestEpisodeID.rawValue)
            ),
            payload: .episode(
                NoteSyncEpisodePayload(
                    chapterID: WorkStableID(rawValue: cloudTestEpisodeID.rawValue),
                    title: "長い話",
                    content: content,
                    memo: ""
                )
            )
        )
        let encoded = try codec.makeNoteRecord(episode)
        defer {
            if let staged = encoded.stagedAsset {
                codec.removeStagedAssets([staged])
            }
        }
        #expect(encoded.stagedAsset != nil)
        #expect(encoded.record[CloudKitSyncSchema.Field.payloadJSON] == nil)
        #expect(try codec.decodeNoteRecord(encoded.record) == episode)
    }
}

@Suite("Note catalog decoder")
struct CloudKitNoteLibraryRecordDecoderTests {
    @Test("malformed note work rows are isolated and valid WorkIDs remain")
    func isolatesMalformedNoteWorks() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let valid = try NoteSyncRecord(
            key: .work(cloudTestWorkID),
            payload: .work(
                NoteSyncWorkPayload(
                    documentID: WorkStableID(
                        rawValue: #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
                    ),
                    title: "valid",
                    synopsis: "",
                    chapterOrder: [],
                    characterOrder: [],
                    plotCardOrder: [],
                    flagOrder: [],
                    worldNoteOrder: []
                )
            )
        )
        let validRecord = try codec.makeNoteRecord(valid).record
        let malformed = CKRecord(
            recordType: CloudKitSyncSchema.RecordType.noteWork,
            recordID: .noteEntity(.work(SyncWorkID()))
        )
        let decoder = CloudKitNoteLibraryRecordDecoder(codec: codec)
        let entries = decoder.decodeIsolatingMalformed([malformed, validRecord])
        #expect(entries.count == 1)
        #expect(entries[0].workID == cloudTestWorkID)
        #expect(entries[0].headRevisionID == nil)
        #expect(entries[0].title == "valid")
    }
}

@Suite("Note conflict inspector")
struct CloudKitNoteConflictInspectorTests {
    @Test("server digest change without force overwrite is a conflict")
    func serverRecordChangedWithoutForceIsConflict() throws {
        let key = NoteSyncEntityKey.work(cloudTestWorkID)
        let local = try NoteSyncRecord(
            key: key,
            payload: .work(
                NoteSyncWorkPayload(
                    documentID: WorkStableID(rawValue: cloudTestWorkID.rawValue),
                    title: "local",
                    synopsis: "",
                    chapterOrder: [],
                    characterOrder: [],
                    plotCardOrder: [],
                    flagOrder: [],
                    worldNoteOrder: []
                )
            )
        )
        let remote = try NoteSyncRecord(
            key: key,
            payload: .work(
                NoteSyncWorkPayload(
                    documentID: WorkStableID(rawValue: cloudTestWorkID.rawValue),
                    title: "remote",
                    synopsis: "",
                    chapterOrder: [],
                    characterOrder: [],
                    plotCardOrder: [],
                    flagOrder: [],
                    worldNoteOrder: []
                )
            )
        )
        let classified = CloudKitNoteConflictInspector.classifySaves(
            incoming: [local],
            existing: [key: remote],
            expectedDigests: [key: local.digest],
            forceOverwrite: []
        )
        #expect(classified.accepted.isEmpty)
        #expect(classified.conflicts == [remote])

        let forced = CloudKitNoteConflictInspector.classifySaves(
            incoming: [local],
            existing: [key: remote],
            expectedDigests: [key: local.digest],
            forceOverwrite: [key]
        )
        #expect(forced.accepted == [local])
        #expect(forced.conflicts.isEmpty)
    }
}
