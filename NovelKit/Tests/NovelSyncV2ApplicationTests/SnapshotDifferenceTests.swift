import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

struct SnapshotDifferenceTests {
    private let workID = WorkID(UUID())
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func encode(_ document: NovelDocument, parents: [SnapshotID] = []) throws -> EncodedSnapshot {
        try SnapshotCodec.encode(SnapshotModel(workId: workID, document: document, documentCreatedAt: createdAt), parents: parents)
    }

    private func document(_ bodies: [String]) -> NovelDocument {
        NovelDocument(title: "作品", chapters: [Chapter(title: "章", episodes: bodies.enumerated().map {
            Episode(title: "タイトル\($0.offset + 1)", content: $0.element)
        })])
    }

    private func compare(_ old: EncodedSnapshot, _ new: EncodedSnapshot,
                         reads: DifferenceReadLog = DifferenceReadLog()) async throws -> SnapshotDifference {
        try await SnapshotDifferenceCalculator.compare(before: old.manifest, after: new.manifest) { after, entry in
            await reads.append(entry.entityKey)
            return try #require((after ? new : old).objects[entry.objectId])
        }
    }

    @Test func oneEpisodeUsesGraphemeCountAndArrayNumber() async throws {
        var doc = document(["前", "前", "👨‍👩‍👧‍👦"])
        let old = try encode(doc)
        doc.chapters[0].episodes[2].content = String(repeating: "文", count: 310)
        let result = try await compare(old, encode(doc))
        #expect(result.line == "第3話「タイトル3」 1字 → 310字")
        #expect(result.reduction == nil)
        #expect(result.hasLargeReduction)
        let reversed = try await compare(encode(doc), old)
        #expect(reversed.reduction?.afterCount == 1)
    }

    @Test func multipleEpisodesShowLargestAndRemainder() async throws {
        var doc = document(["あ", "あ", "あ"])
        let old = try encode(doc)
        for index in 0 ..< 3 {
            doc.chapters[0].episodes[index].content = String(repeating: "文", count: (index + 1) * 100)
        }
        let result = try await compare(old, encode(doc))
        #expect(result.line == "第3話「タイトル3」 1字 → 300字 ほか2件")
        #expect(result.episodes.map(\.number) == [1, 2, 3])
    }

    @Test func metadataOnlyDoesNotReadObjects() async throws {
        var doc = document(["本文"])
        let old = try encode(doc)
        doc.characters = [Character(name: "人物")]
        doc.worldNotes = [WorldNote(title: "設定", content: "内容")]
        let reads = DifferenceReadLog()
        #expect(try await compare(old, encode(doc), reads: reads).line == "人物・設定の変更")
        #expect(await reads.keys.isEmpty)
    }

    @Test func unchangedAndUnfetchedReadNothing() async throws {
        let old = try encode(document(["本文"]))
        let reads = DifferenceReadLog()
        #expect(try await compare(old, old, reads: reads).line == "内容の変更なし")
        let missing = try await SnapshotDifferenceCalculator.compare(before: old.manifest, after: nil) { _, _ in
            Issue.record("Unfetched snapshots must not read any objects")
            return Data()
        }
        #expect(missing == .unfetched)
        #expect(await reads.keys.isEmpty)
    }

    @Test(arguments: [("", true), ("あい", true), ("あいう", false)])
    func reductionIncludesEmptyAndHalf(value: String, expected: Bool) async throws {
        var doc = document(["あいうえ"])
        let old = try encode(doc)
        doc.chapters[0].episodes[0].content = value
        #expect(try await (compare(old, encode(doc)).reduction != nil) == expected)
    }

    @Test func reorderOnlyIsMetadataAndNeverReadsBodies() async throws {
        var doc = document(["あ", "い", "う"])
        let old = try encode(doc)
        doc.chapters[0].episodes.reverse()
        let reads = DifferenceReadLog()
        let new = try encode(doc)
        #expect(try await compare(old, new, reads: reads).line == "話の順序の変更")
        #expect(await reads.keys.isEmpty)
        let earlierFirst = doc.chapters[0].episodes[0].id
        doc.chapters[0].episodes[0].content = "変わった本文"
        let result = try await compare(new, encode(doc))
        #expect(result.episodes.first?.id == earlierFirst.rawValue.uuidString.lowercased())
        #expect(result.episodes.first?.number == 1)
    }

    @Test func largeWorkReadsOnlyChangedBodiesAndTheirContext() async throws {
        var doc = document(Array(repeating: String(repeating: "文", count: 1000), count: 1000))
        let old = try encode(doc)
        doc.chapters[0].episodes[777].content = "短い本文"
        let reads = DifferenceReadLog()
        let result = try await compare(old, encode(doc), reads: reads)
        #expect(result.episodes.first?.number == 778)
        let keys = await reads.keys
        #expect(keys.count(where: { $0.hasSuffix("/body") }) == 2)
        #expect(keys.count <= 5)
        #expect(!keys.contains { $0.hasPrefix("attachment/") })
    }

    @Test func removedEpisodeUsesItsPreviousTitleAndOrder() async throws {
        var doc = document(["あ", "削除する本文"])
        let old = try encode(doc)
        doc.chapters[0].episodes.removeLast()
        let result = try await compare(old, encode(doc))
        #expect(result.line == "第2話「タイトル2」 6字 → 0字")
        #expect(result.reduction != nil)
    }
}

private actor DifferenceReadLog {
    var keys: [String] = []
    func append(_ key: String) {
        keys.append(key)
    }
}
