import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("Sync work structure digest")
struct SyncWorkStructureDigestTests {
    @Test("only ordered chapter and episode IDs affect the digest")
    func identityAndOrderOnly() throws {
        let chapterAID = try ChapterID(
            rawValue: #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        )
        let chapterBID = try ChapterID(
            rawValue: #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002"))
        )
        let episodeAID = try EpisodeID(
            rawValue: #require(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001"))
        )
        let episodeBID = try EpisodeID(
            rawValue: #require(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"))
        )
        let original = [
            Chapter(
                id: chapterAID,
                title: "章A",
                episodes: [Episode(id: episodeAID, title: "話A", content: "本文A")]
            ),
            Chapter(
                id: chapterBID,
                title: "章B",
                episodes: [Episode(id: episodeBID, title: "話B", content: "本文B")]
            )
        ]
        let metadataChanged = [
            Chapter(
                id: chapterAID,
                title: "changed",
                episodes: [Episode(id: episodeAID, title: "changed", content: "changed")]
            ),
            Chapter(
                id: chapterBID,
                title: "changed",
                episodes: [Episode(id: episodeBID, title: "changed", content: "changed")]
            )
        ]

        let originalDigest = try SyncWorkStructureDigest(chapters: original)
        let metadataChangedDigest = try SyncWorkStructureDigest(chapters: metadataChanged)
        let reversedDigest = try SyncWorkStructureDigest(chapters: Array(original.reversed()))

        #expect(originalDigest == metadataChangedDigest)
        #expect(
            originalDigest != reversedDigest
        )
    }

    @Test("duplicate IDs are rejected instead of producing an ambiguous binding digest")
    func duplicateIDsFailClosed() {
        let chapterID = ChapterID()
        let episodeID = EpisodeID()
        let duplicateChapters = [
            Chapter(id: chapterID, title: "A", episodes: []),
            Chapter(id: chapterID, title: "B", episodes: [])
        ]
        #expect(throws: SyncWorkStructureError.self) {
            _ = try SyncWorkStructureDigest(chapters: duplicateChapters)
        }

        let duplicateEpisodes = [
            Chapter(
                title: "A",
                episodes: [Episode(id: episodeID), Episode(id: episodeID)]
            )
        ]
        #expect(throws: SyncWorkStructureError.self) {
            _ = try SyncWorkStructureDigest(chapters: duplicateEpisodes)
        }
    }

    @Test("descriptor golden fixture carries the required structure digest")
    func descriptorGoldenFixture() throws {
        let url = try #require(
            Bundle.module.url(forResource: "sync-work-descriptor-v1", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let descriptor = try JSONDecoder().decode(SyncWorkDescriptor.self, from: data)
        let emptyStructureDigest = try SyncWorkStructureDigest(chapters: [])
        #expect(descriptor.structureDigest == emptyStructureDigest)

        let encoded = try JSONEncoder().encode(descriptor)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["structureDigest"] as? String == descriptor.structureDigest.rawValue)
    }
}
