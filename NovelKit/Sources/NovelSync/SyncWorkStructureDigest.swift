import NovelCore

public enum SyncWorkStructureError: Error, Equatable, Sendable {
    case duplicateChapterID
    case duplicateEpisodeID
}

/// ordered ChapterID + ordered EpisodeID graphだけのportable digest。
/// title、本文、memo、path、端末identityは入力へ含めない。
public struct SyncWorkStructureDigest: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(chapters: [Chapter]) throws {
        var chapterIDs: Set<ChapterID> = []
        var episodeIDs: Set<EpisodeID> = []
        var canonical = "FUMINIWA_SYNC_STRUCTURE_V1\nCHAPTERS:\(chapters.count)\n"
        for chapter in chapters {
            guard chapterIDs.insert(chapter.id).inserted else {
                throw SyncWorkStructureError.duplicateChapterID
            }
            canonical += "C:\(chapter.id.rawValue.uuidString):\(chapter.episodes.count)\n"
            for episode in chapter.episodes {
                guard episodeIDs.insert(episode.id).inserted else {
                    throw SyncWorkStructureError.duplicateEpisodeID
                }
                canonical += "E:\(episode.id.rawValue.uuidString)\n"
            }
        }
        rawValue = SyncContentDigest(content: canonical).rawValue
    }

    public init(validating rawValue: String) throws {
        self.rawValue = try SyncContentDigest(validating: rawValue).rawValue
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(validating: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "structureDigest must be a lowercase SHA-256 value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
