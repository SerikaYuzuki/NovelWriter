import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test(.serialized, arguments: [(1000, 1), (100_000, 100), (300_000, 150), (1_000_000, 300)], [false, true])
func checkpointPreservesCanonicalRows(size: (Int, Int), attached: Bool) async throws {
    let root = temporaryStoreRoot("checkpoint-rows")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    var doc = NovelDocument(title: "合成", chapters: [Chapter(title: "章", episodes: (0 ..< size.1).map {
        Episode(title: "話\($0)", content: String(repeating: "文", count: size.0 / size.1))
    })])
    let attachments = attached ? [
        SyncAttachment(attachmentId: UUID(), fileName: "test.bin", bytes: Data([0, 1, 255]))
    ] :
        []
    var generation: Int64 = 0
    for changed in [false, true] {
        if changed {
            doc.chapters[0].episodes[0].content += "字"
        }
        let parents = try await store.referenceParents(work: work)
        let reference = try SnapshotCodec.encode(SnapshotModel(workId: work,
                                                               document: doc,
                                                               documentCreatedAt: testDate,
                                                               attachments: attachments),
                                                 parents: parents)
        let result = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                                    document: doc,
                                                                    documentCreatedAt: testDate,
                                                                    expectedGeneration: generation,
                                                                    reason: .autosave,
                                                                    attachments: attachments),
                                                scope: .unbound)
        generation += 1
        #expect(result.snapshotID == reference.snapshotId)
        #expect(result.generation == generation)
        try await store.assertCanonicalRows(reference, generation: generation)
    }
    await store.close()
}

@Test(arguments: ["unchanged", "body", "metadata", "attachment", "resource", "order"])
func checkpointNoChangeMatchesOriginal(change: String) async throws {
    let root = temporaryStoreRoot("checkpoint-comparison")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    var document = NovelDocument(title: "before", chapters: [Chapter(title: "章", episodes: [
        Episode(title: "一", content: "本文"), Episode(title: "二", content: "続き")
    ])])
    let id = UUID()
    var attachments = [SyncAttachment(attachmentId: id, fileName: "test.bin", bytes: Data([1]))]
    var resources = [PortableResource(pathComponents: ["opaque.bin"], kind: .regularFile, bytes: Data([2]))]
    let first = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                               document: document,
                                                               documentCreatedAt: testDate,
                                                               expectedGeneration: 0,
                                                               reason: .autosave,
                                                               attachments: attachments,
                                                               resources: resources),
                                           scope: .unbound)
    switch change {
    case "body": document.chapters[0].episodes[0].content += "字"
    case "metadata": document.title += "題"
    case "attachment": attachments = [SyncAttachment(attachmentId: id, fileName: "test.bin", bytes: Data([3]))]
    case "resource": resources = [PortableResource(pathComponents: ["opaque.bin"],
                                                   kind: .regularFile,
                                                   bytes: Data([4]))]
    case "order": document.chapters[0].episodes.reverse()
    default: break
    }
    let candidate = try SnapshotCodec.encode(SnapshotModel(workId: work,
                                                           document: document,
                                                           documentCreatedAt: testDate,
                                                           attachments: attachments),
                                             parents: [])
    let legacyMatches = try await store.legacyContentMatches(work: work,
                                                             current: first.snapshotID,
                                                             candidate: candidate)
    #expect(try await store
        .contentMatches(work: work, current: first.snapshotID, candidate: candidate) == legacyMatches)
    let second = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                                document: document,
                                                                documentCreatedAt: testDate,
                                                                expectedGeneration: first.generation,
                                                                reason: .autosave,
                                                                attachments: attachments,
                                                                resources: resources),
                                            scope: .unbound)
    #expect(second.noChanges == (change == "unchanged"))
    try await store.assertStableContentMatches(work: work, document: document, attachments: attachments, result: second)
    await store.close()
}

private extension LocalSyncV2Store {
    func assertStableContentMatches(work: WorkID, document: NovelDocument, attachments: [SyncAttachment],
                                    result: V2CheckpointResult) throws {
        // Stable heads have different parents even for identical content; entries remain the equivalence criterion.
        _ = try promoteCurrentLeaf(workID: work, scope: .unbound)
        let stable = try workSummary(workID: work, scope: .unbound)
        let stableCandidate = try SnapshotCodec.encode(SnapshotModel(workId: work,
                                                                     document: document,
                                                                     documentCreatedAt: testDate,
                                                                     attachments: attachments),
                                                       parents: [result.snapshotID])
        #expect(stableCandidate.snapshotId != result.snapshotID)
        #expect(try contentMatches(work: work,
                                   current: #require(stable.currentSnapshotID),
                                   candidate: stableCandidate))
    }

    func referenceParents(work: WorkID) throws -> [SnapshotID] {
        guard let bytes = try workRepository.scopedWorkRow(workID: work, scope: .unbound)?.currentSnapshotID else {
            return []
        }
        return try workRepository.checkpointParents(workID: work, current: SnapshotID(rawValue: bytes.hexString))
    }

    func legacyContentMatches(work: WorkID, current: SnapshotID, candidate: EncodedSnapshot) throws -> Bool {
        let old = try workRepository.loadEncoded(workID: work, snapshotID: current)
        return old.manifest.entries == candidate.manifest.entries && old.objects == candidate.objects
    }

    func contentMatches(work: WorkID, current: SnapshotID, candidate: EncodedSnapshot) throws -> Bool {
        try workRepository.checkpointContentMatches(workID: work, current: current, candidate: candidate)
    }

    func assertCanonicalRows(_ expected: EncodedSnapshot, generation: Int64) throws {
        let actual = try workRepository.loadEncoded(workID: expected.manifest.workId, snapshotID: expected.snapshotId)
        #expect(actual.manifestBytes == expected.manifestBytes)
        #expect(actual.objects == expected.objects)
        #expect(actual.manifest == expected.manifest)
        // loadEncoded attests exact snapshot_entries and parent rows against the unchanged codec.
        let work = try #require(try workRepository.scopedWorkRow(workID: expected.manifest.workId, scope: .unbound))
        let model = try SnapshotCodec.decode(expected)
        #expect(work.currentSnapshotID == expected.snapshotId.bytes)
        #expect(work.localGeneration == generation)
        #expect(work.documentID == DocumentID(model.document.id).description)
        #expect(try work.documentCreatedAt == (StoreValueCoding.iso8601(testDate)))
        let history = try workRepository.history(workID: expected.manifest.workId, scope: .unbound)
        #expect(history.count == Int(generation))
        #expect(history.last?.snapshotID == expected.snapshotId)
        #expect(history.last?.reason == "autosaveLeaf")
        #expect(history.last?.pinned == false)
        #expect(history.last?.localGeneration == generation)
    }
}
