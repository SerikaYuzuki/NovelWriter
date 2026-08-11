// Canonical wire model intentionally keeps validation adjacent to every encoded field.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable file_length type_body_length function_body_length
import Foundation
import NovelCore

public enum WorkSnapshotError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case tooManyEntities
    case duplicateIdentifier
    case nonCanonicalEntityOrder
    case invalidEntityReference
    case stringTooLarge
    case snapshotTooLarge(actualBytes: Int, maximumBytes: Int)
    case nonCanonicalJSON
    case documentIdentityMismatch
}

/// 作品snapshot内のstable ID。wireではcanonical uppercase UUID文字列だけを受け付ける。
public struct WorkStableID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

public struct WorkChapterSnapshot: Hashable, Codable, Sendable {
    public let id: WorkStableID
    public let title: String
    public let episodeOrder: [WorkStableID]
}

public struct WorkEpisodeSnapshot: Hashable, Codable, Sendable {
    public let id: WorkStableID
    public let title: String
    public let content: String
    public let memo: String
}

public struct WorkCharacterSnapshot: Hashable, Codable, Sendable {
    public let id: WorkStableID
    public let name: String
    public let kana: String
    public let memo: String
    public let colorHex: String?
    public let role: String?
    public let age: String?
    public let gender: String?
    public let firstPerson: String?
    public let secondPerson: String?
    public let speechStyle: String?
    public let appearance: String?
    public let personality: String?
    public let background: String?
}

public struct WorkPlotCardSnapshot: Hashable, Codable, Sendable {
    public let id: WorkStableID
    public let title: String
    public let memo: String
    public let chapterID: WorkStableID?
}

public struct WorkFlagSnapshot: Hashable, Codable, Sendable {
    public let id: WorkStableID
    public let title: String
    public let note: String
    public let isResolved: Bool
    public let plantedChapterID: WorkStableID?
    public let resolvedChapterID: WorkStableID?
}

public struct WorkWorldNoteSnapshot: Hashable, Codable, Sendable {
    public let id: WorkStableID
    public let title: String
    public let content: String
}

/// `NovelDocument`全体のportable canonical snapshot。
///
/// entity本体はID順、表示順はorder列へ分ける。端末設定、選択状態、snapshot履歴、
/// package pathは含めない。資料binaryはNovelDocument外なのでこのv1 payloadには含めない。
public struct WorkSnapshot: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case snapshotVersion
        case documentID
        case title
        case synopsis
        case chapterOrder
        case chapters
        case episodes
        case characterOrder
        case characters
        case plotCardOrder
        case plotCards
        case flagOrder
        case flags
        case worldNoteOrder
        case worldNotes
    }

    public static let currentVersion = 1
    public static let maximumCanonicalByteCount = 48 * 1024 * 1024
    public static let maximumStringUTF8Bytes = 1 * 1024 * 1024
    public static let maximumEntityCountPerKind = 20000
    public static let maximumTotalEntityCount = 50000

    public let snapshotVersion: Int
    public let documentID: WorkStableID
    public let title: String
    public let synopsis: String
    public let chapterOrder: [WorkStableID]
    public let chapters: [WorkChapterSnapshot]
    public let episodes: [WorkEpisodeSnapshot]
    public let characterOrder: [WorkStableID]
    public let characters: [WorkCharacterSnapshot]
    public let plotCardOrder: [WorkStableID]
    public let plotCards: [WorkPlotCardSnapshot]
    public let flagOrder: [WorkStableID]
    public let flags: [WorkFlagSnapshot]
    public let worldNoteOrder: [WorkStableID]
    public let worldNotes: [WorkWorldNoteSnapshot]

    public init(document: NovelDocument) throws {
        snapshotVersion = Self.currentVersion
        documentID = WorkStableID(rawValue: document.id)
        title = document.title
        synopsis = document.synopsis
        chapterOrder = document.chapters.map { WorkStableID(rawValue: $0.id.rawValue) }
        chapters = document.chapters.map { chapter in
            WorkChapterSnapshot(
                id: WorkStableID(rawValue: chapter.id.rawValue),
                title: chapter.title,
                episodeOrder: chapter.episodes.map { WorkStableID(rawValue: $0.id.rawValue) }
            )
        }.sortedByStableID()
        episodes = document.chapters.flatMap(\.episodes).map { episode in
            WorkEpisodeSnapshot(
                id: WorkStableID(rawValue: episode.id.rawValue),
                title: episode.title,
                content: episode.content,
                memo: episode.memo
            )
        }.sortedByStableID()
        characterOrder = document.characters.map { WorkStableID(rawValue: $0.id.rawValue) }
        characters = document.characters.map { character in
            WorkCharacterSnapshot(
                id: WorkStableID(rawValue: character.id.rawValue),
                name: character.name,
                kana: character.kana,
                memo: character.memo,
                colorHex: character.colorHex,
                role: character.role,
                age: character.age,
                gender: character.gender,
                firstPerson: character.firstPerson,
                secondPerson: character.secondPerson,
                speechStyle: character.speechStyle,
                appearance: character.appearance,
                personality: character.personality,
                background: character.background
            )
        }.sortedByStableID()
        plotCardOrder = document.plotCards.map { WorkStableID(rawValue: $0.id.rawValue) }
        plotCards = document.plotCards.map { card in
            WorkPlotCardSnapshot(
                id: WorkStableID(rawValue: card.id.rawValue),
                title: card.title,
                memo: card.memo,
                chapterID: card.chapterID.map { WorkStableID(rawValue: $0.rawValue) }
            )
        }.sortedByStableID()
        flagOrder = document.flags.map { WorkStableID(rawValue: $0.id.rawValue) }
        flags = document.flags.map { flag in
            WorkFlagSnapshot(
                id: WorkStableID(rawValue: flag.id.rawValue),
                title: flag.title,
                note: flag.note,
                isResolved: flag.isResolved,
                plantedChapterID: flag.plantedChapterID.map { WorkStableID(rawValue: $0.rawValue) },
                resolvedChapterID: flag.resolvedChapterID.map { WorkStableID(rawValue: $0.rawValue) }
            )
        }.sortedByStableID()
        worldNoteOrder = document.worldNotes.map { WorkStableID(rawValue: $0.id.rawValue) }
        worldNotes = document.worldNotes.map { note in
            WorkWorldNoteSnapshot(
                id: WorkStableID(rawValue: note.id.rawValue),
                title: note.title,
                content: note.content
            )
        }.sortedByStableID()
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotVersion = try container.decode(Int.self, forKey: .snapshotVersion)
        documentID = try container.decode(WorkStableID.self, forKey: .documentID)
        title = try container.decode(String.self, forKey: .title)
        synopsis = try container.decode(String.self, forKey: .synopsis)
        chapterOrder = try container.decode([WorkStableID].self, forKey: .chapterOrder)
        chapters = try container.decode([WorkChapterSnapshot].self, forKey: .chapters)
        episodes = try container.decode([WorkEpisodeSnapshot].self, forKey: .episodes)
        characterOrder = try container.decode([WorkStableID].self, forKey: .characterOrder)
        characters = try container.decode([WorkCharacterSnapshot].self, forKey: .characters)
        plotCardOrder = try container.decode([WorkStableID].self, forKey: .plotCardOrder)
        plotCards = try container.decode([WorkPlotCardSnapshot].self, forKey: .plotCards)
        flagOrder = try container.decode([WorkStableID].self, forKey: .flagOrder)
        flags = try container.decode([WorkFlagSnapshot].self, forKey: .flags)
        worldNoteOrder = try container.decode([WorkStableID].self, forKey: .worldNoteOrder)
        worldNotes = try container.decode([WorkWorldNoteSnapshot].self, forKey: .worldNotes)
        try validate()
    }

    public func materializedDocument() throws -> NovelDocument {
        try validate()
        let episodeMap = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
        let chapterMap = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0) })
        let characterMap = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
        let plotMap = Dictionary(uniqueKeysWithValues: plotCards.map { ($0.id, $0) })
        let flagMap = Dictionary(uniqueKeysWithValues: flags.map { ($0.id, $0) })
        let worldMap = Dictionary(uniqueKeysWithValues: worldNotes.map { ($0.id, $0) })

        return try NovelDocument(
            id: documentID.rawValue,
            title: title,
            synopsis: synopsis,
            chapters: chapterOrder.map { chapterID in
                guard let chapter = chapterMap[chapterID] else {
                    throw WorkSnapshotError.invalidEntityReference
                }
                return try Chapter(
                    id: ChapterID(rawValue: chapter.id.rawValue),
                    title: chapter.title,
                    episodes: chapter.episodeOrder.map { episodeID in
                        guard let episode = episodeMap[episodeID] else {
                            throw WorkSnapshotError.invalidEntityReference
                        }
                        return Episode(
                            id: EpisodeID(rawValue: episode.id.rawValue),
                            title: episode.title,
                            content: episode.content,
                            memo: episode.memo
                        )
                    }
                )
            },
            characters: characterOrder.map { id in
                guard let value = characterMap[id] else {
                    throw WorkSnapshotError.invalidEntityReference
                }
                return Character(
                    id: CharacterID(rawValue: value.id.rawValue),
                    name: value.name,
                    kana: value.kana,
                    memo: value.memo,
                    colorHex: value.colorHex,
                    role: value.role,
                    age: value.age,
                    gender: value.gender,
                    firstPerson: value.firstPerson,
                    secondPerson: value.secondPerson,
                    speechStyle: value.speechStyle,
                    appearance: value.appearance,
                    personality: value.personality,
                    background: value.background
                )
            },
            plotCards: plotCardOrder.map { id in
                guard let value = plotMap[id] else {
                    throw WorkSnapshotError.invalidEntityReference
                }
                return PlotCard(
                    id: PlotCardID(rawValue: value.id.rawValue),
                    title: value.title,
                    memo: value.memo,
                    chapterID: value.chapterID.map { ChapterID(rawValue: $0.rawValue) }
                )
            },
            flags: flagOrder.map { id in
                guard let value = flagMap[id] else {
                    throw WorkSnapshotError.invalidEntityReference
                }
                return Flag(
                    id: FlagID(rawValue: value.id.rawValue),
                    title: value.title,
                    note: value.note,
                    isResolved: value.isResolved,
                    plantedChapterID: value.plantedChapterID.map { ChapterID(rawValue: $0.rawValue) },
                    resolvedChapterID: value.resolvedChapterID.map { ChapterID(rawValue: $0.rawValue) }
                )
            },
            worldNotes: worldNoteOrder.map { id in
                guard let value = worldMap[id] else {
                    throw WorkSnapshotError.invalidEntityReference
                }
                return WorldNote(
                    id: WorldNoteID(rawValue: value.id.rawValue),
                    title: value.title,
                    content: value.content
                )
            }
        )
    }

    public func validate() throws {
        guard snapshotVersion == Self.currentVersion else {
            throw WorkSnapshotError.unsupportedVersion(snapshotVersion)
        }
        let collections = [
            chapters.count, episodes.count, characters.count,
            plotCards.count, flags.count, worldNotes.count
        ]
        guard collections.allSatisfy({ $0 <= Self.maximumEntityCountPerKind }),
              collections.reduce(0, +) <= Self.maximumTotalEntityCount else {
            throw WorkSnapshotError.tooManyEntities
        }
        try validateCanonical(chapters, order: chapterOrder)
        try validateCanonical(characters, order: characterOrder)
        try validateCanonical(plotCards, order: plotCardOrder)
        try validateCanonical(flags, order: flagOrder)
        try validateCanonical(worldNotes, order: worldNoteOrder)
        guard episodes.map(\.id) == episodes.map(\.id).sortedByUUIDString(),
              Set(episodes.map(\.id)).count == episodes.count else {
            throw WorkSnapshotError.nonCanonicalEntityOrder
        }
        let referencedEpisodes = chapters.flatMap(\.episodeOrder)
        guard Set(referencedEpisodes).count == referencedEpisodes.count,
              Set(referencedEpisodes) == Set(episodes.map(\.id)) else {
            throw WorkSnapshotError.invalidEntityReference
        }
        let chapterIDs = Set(chapterOrder)
        guard plotCards.allSatisfy({ $0.chapterID.map(chapterIDs.contains) ?? true }),
              flags.allSatisfy({ flag in
                  (flag.plantedChapterID.map(chapterIDs.contains) ?? true)
                      && (flag.resolvedChapterID.map(chapterIDs.contains) ?? true)
              }) else {
            throw WorkSnapshotError.invalidEntityReference
        }
        guard allStrings().allSatisfy({ $0.utf8.count <= Self.maximumStringUTF8Bytes }) else {
            throw WorkSnapshotError.stringTooLarge
        }
        let byteCount = try WorkCanonicalJSON.uncheckedEncoder().encode(self).count
        guard byteCount <= Self.maximumCanonicalByteCount else {
            throw WorkSnapshotError.snapshotTooLarge(
                actualBytes: byteCount,
                maximumBytes: Self.maximumCanonicalByteCount
            )
        }
    }

    private func validateCanonical(
        _ entities: [some WorkSnapshotEntity],
        order: [WorkStableID]
    ) throws {
        let ids = entities.map(\.id)
        guard ids == ids.sortedByUUIDString() else {
            throw WorkSnapshotError.nonCanonicalEntityOrder
        }
        guard Set(ids).count == ids.count, Set(order).count == order.count else {
            throw WorkSnapshotError.duplicateIdentifier
        }
        guard Set(ids) == Set(order) else {
            throw WorkSnapshotError.invalidEntityReference
        }
    }

    private func allStrings() -> [String] {
        [title, synopsis]
            + chapters.map(\.title)
            + episodes.flatMap { [$0.title, $0.content, $0.memo] }
            + characters.flatMap {
                [$0.name, $0.kana, $0.memo]
                    + [$0.colorHex, $0.role, $0.age, $0.gender, $0.firstPerson,
                       $0.secondPerson, $0.speechStyle, $0.appearance, $0.personality,
                       $0.background].compactMap(\.self)
            }
            + plotCards.flatMap { [$0.title, $0.memo] }
            + flags.flatMap { [$0.title, $0.note] }
            + worldNotes.flatMap { [$0.title, $0.content] }
    }
}

public enum WorkCanonicalJSON {
    public static func encodeSnapshot(_ snapshot: WorkSnapshot) throws -> Data {
        try snapshot.validate()
        return try uncheckedEncoder().encode(snapshot)
    }

    public static func decodeSnapshot(_ data: Data) throws -> WorkSnapshot {
        guard data.count <= WorkSnapshot.maximumCanonicalByteCount else {
            throw WorkSnapshotError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: WorkSnapshot.maximumCanonicalByteCount
            )
        }
        let snapshot = try JSONDecoder().decode(WorkSnapshot.self, from: data)
        guard try uncheckedEncoder().encode(snapshot) == data else {
            throw WorkSnapshotError.nonCanonicalJSON
        }
        return snapshot
    }

    static func uncheckedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private protocol WorkSnapshotEntity {
    var id: WorkStableID { get }
}

extension WorkChapterSnapshot: WorkSnapshotEntity {}
extension WorkEpisodeSnapshot: WorkSnapshotEntity {}
extension WorkCharacterSnapshot: WorkSnapshotEntity {}
extension WorkPlotCardSnapshot: WorkSnapshotEntity {}
extension WorkFlagSnapshot: WorkSnapshotEntity {}
extension WorkWorldNoteSnapshot: WorkSnapshotEntity {}

private extension Array where Element: WorkSnapshotEntity {
    func sortedByStableID() -> [Element] {
        sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }
}

private extension [WorkStableID] {
    func sortedByUUIDString() -> [WorkStableID] {
        sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
}
