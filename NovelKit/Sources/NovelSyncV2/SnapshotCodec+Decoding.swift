import Foundation
import NovelCore

struct SnapshotDecodingContext {
    private let manifest: SnapshotManifest
    private let objects: [ObjectID: Data]
    private let entriesByKey: [String: SnapshotEntry]
    private var expectedEntityKeys: Set<String> = [
        "work/document",
        "work/title",
        "work/synopsis",
        "work/chapter-order",
        "work/character-order",
        "work/plot-card-order",
        "work/flag-order",
        "work/world-note-order",
        "work/attachment-order"
    ]

    init(manifestBytes: Data, objects: [ObjectID: Data]) throws {
        let manifest = try SnapshotValidator.validate(manifestBytes: manifestBytes)
        let encoded = EncodedSnapshot(
            manifest: manifest,
            manifestBytes: manifestBytes,
            objects: objects
        )
        try SnapshotValidator.validateObjects(encoded)
        self.manifest = manifest
        self.objects = objects
        entriesByKey = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.entityKey, $0) }
        )
    }

    mutating func decode() throws -> SnapshotModel {
        let documentInfo = try SnapshotCodec.fields(
            data("work/document"),
            allowed: ["documentCreatedAt", "documentId"]
        )
        let documentIDString = try SnapshotCodec.string(documentInfo, "documentId")
        guard let documentID = SyncV2UUID.parse(documentIDString) else {
            throw SyncV2TypeError.invalidUUID
        }
        let createdAtString = try SnapshotCodec.string(documentInfo, "documentCreatedAt")
        let createdAt = try SnapshotCodec.parseDate(createdAtString)
        let chapterIDs = try SnapshotCodec.order(data("work/chapter-order"))
        let characterIDs = try SnapshotCodec.order(data("work/character-order"))
        let plotCardIDs = try SnapshotCodec.order(data("work/plot-card-order"))
        let flagIDs = try SnapshotCodec.order(data("work/flag-order"))
        let worldNoteIDs = try SnapshotCodec.order(data("work/world-note-order"))
        let attachmentIDs = try SnapshotCodec.order(data("work/attachment-order"))
        let chapters = try decodeChapters(chapterIDs)
        let characters = try decodeCharacters(characterIDs)
        let cards = try decodePlotCards(plotCardIDs, chapterIDs: Set(chapterIDs))
        let flags = try decodeFlags(
            flagIDs,
            chapterIDs: Set(chapterIDs)
        )
        let notes = try decodeWorldNotes(worldNoteIDs)
        let attachments = try decodeAttachments(attachmentIDs)

        guard Set(entriesByKey.keys) == expectedEntityKeys else {
            throw SyncV2TypeError.referenceViolation("entity closure")
        }
        let document = try NovelDocument(
            id: documentID,
            title: SnapshotCodec.valueString(data("work/title")),
            synopsis: SnapshotCodec.valueString(data("work/synopsis")),
            chapters: chapters,
            characters: characters,
            plotCards: cards,
            flags: flags,
            worldNotes: notes
        )
        return SnapshotModel(
            workId: manifest.workId,
            document: document,
            documentCreatedAt: createdAt,
            attachments: attachments
        )
    }

    private mutating func decodeChapters(_ chapterIDs: [String]) throws -> [Chapter] {
        var chapters: [Chapter] = []
        var ownedEpisodes = Set<String>()
        for chapterID in chapterIDs {
            let chapterPrefix = "chapter/\(chapterID)"
            let titleKey = "\(chapterPrefix)/title"
            let orderKey = "\(chapterPrefix)/episode-order"
            expectedEntityKeys.formUnion([titleKey, orderKey])
            let episodeIDs = try SnapshotCodec.order(data(orderKey))
            let episodes = try decodeEpisodes(
                episodeIDs,
                ownedEpisodes: &ownedEpisodes
            )
            guard let rawChapterID = SyncV2UUID.parse(chapterID) else {
                throw SyncV2TypeError.invalidUUID
            }
            let title = try SnapshotCodec.valueString(data(titleKey))
            chapters.append(
                Chapter(
                    id: ChapterID(rawValue: rawChapterID),
                    title: title,
                    episodes: episodes
                )
            )
        }
        return chapters
    }

    private mutating func decodeEpisodes(
        _ episodeIDs: [String],
        ownedEpisodes: inout Set<String>
    ) throws -> [Episode] {
        var episodes: [Episode] = []
        for episodeID in episodeIDs {
            guard ownedEpisodes.insert(episodeID).inserted else {
                throw SyncV2TypeError.referenceViolation("episode ownership")
            }
            let prefix = "episode/\(episodeID)"
            let titleKey = "\(prefix)/title"
            let bodyKey = "\(prefix)/body"
            let memoKey = "\(prefix)/memo"
            expectedEntityKeys.formUnion([titleKey, bodyKey, memoKey])
            guard let rawEpisodeID = SyncV2UUID.parse(episodeID) else {
                throw SyncV2TypeError.invalidUUID
            }
            let title = try SnapshotCodec.valueString(data(titleKey))
            let content = try SnapshotCodec.valueString(data(bodyKey))
            let memo = try SnapshotCodec.valueString(data(memoKey))
            episodes.append(
                Episode(
                    id: EpisodeID(rawValue: rawEpisodeID),
                    title: title,
                    content: content,
                    memo: memo
                )
            )
        }
        return episodes
    }

    private mutating func decodeCharacters(_ identifiers: [String]) throws -> [Character] {
        var characters: [Character] = []
        for identifier in identifiers {
            let key = "character/\(identifier)"
            expectedEntityKeys.insert(key)
            let character = try SnapshotCodec.decodeCharacter(data(key))
            guard character.id.rawValue.uuidString.lowercased() == identifier else {
                throw SyncV2TypeError.referenceViolation(identifier)
            }
            characters.append(character)
        }
        return characters
    }

    private mutating func decodePlotCards(
        _ identifiers: [String],
        chapterIDs: Set<String>
    ) throws -> [PlotCard] {
        var cards: [PlotCard] = []
        for identifier in identifiers {
            let key = "plot-card/\(identifier)"
            expectedEntityKeys.insert(key)
            let card = try SnapshotCodec.decodePlotCard(data(key))
            guard card.id.rawValue.uuidString.lowercased() == identifier,
                  SnapshotCodec.chapterReference(card.chapterID, belongsTo: chapterIDs) else {
                throw SyncV2TypeError.referenceViolation(identifier)
            }
            cards.append(card)
        }
        return cards
    }

    private mutating func decodeFlags(
        _ identifiers: [String],
        chapterIDs: Set<String>
    ) throws -> [Flag] {
        var flags: [Flag] = []
        for identifier in identifiers {
            let key = "flag/\(identifier)"
            expectedEntityKeys.insert(key)
            let flag = try SnapshotCodec.decodeFlag(data(key))
            guard flag.id.rawValue.uuidString.lowercased() == identifier,
                  SnapshotCodec.chapterReference(flag.plantedChapterID, belongsTo: chapterIDs),
                  SnapshotCodec.chapterReference(flag.resolvedChapterID, belongsTo: chapterIDs) else {
                throw SyncV2TypeError.referenceViolation(identifier)
            }
            flags.append(flag)
        }
        return flags
    }

    private mutating func decodeWorldNotes(_ identifiers: [String]) throws -> [WorldNote] {
        var notes: [WorldNote] = []
        for identifier in identifiers {
            let key = "world-note/\(identifier)"
            expectedEntityKeys.insert(key)
            let note = try SnapshotCodec.decodeWorldNote(data(key))
            guard note.id.rawValue.uuidString.lowercased() == identifier else {
                throw SyncV2TypeError.referenceViolation(identifier)
            }
            notes.append(note)
        }
        return notes
    }

    private mutating func decodeAttachments(
        _ identifiers: [String]
    ) throws -> [SyncAttachment] {
        var attachments: [SyncAttachment] = []
        for identifier in identifiers {
            let metadataKey = "attachment/\(identifier)/metadata"
            let bytesKey = "attachment/\(identifier)/bytes"
            expectedEntityKeys.formUnion([metadataKey, bytesKey])
            let metadata = try SnapshotCodec.fields(
                data(metadataKey),
                allowed: ["attachmentId", "byteCount", "fileName"]
            )
            let storedAttachmentID = try SnapshotCodec.string(metadata, "attachmentId")
            let expectedByteCount = try SnapshotCodec.int(metadata, "byteCount")
            guard storedAttachmentID == identifier,
                  let attachmentID = UUID(uuidString: identifier),
                  expectedByteCount >= 0 else {
                throw SyncV2TypeError.referenceViolation(identifier)
            }
            let bytes = try data(bytesKey)
            guard bytes.count == expectedByteCount else {
                throw SyncV2TypeError.byteCountMismatch
            }
            let fileName = try SnapshotCodec.string(metadata, "fileName")
            attachments.append(
                SyncAttachment(
                    attachmentId: attachmentID,
                    fileName: fileName,
                    bytes: bytes
                )
            )
        }
        return attachments
    }

    private func data(_ key: String) throws -> Data {
        guard let entry = entriesByKey[key],
              let bytes = objects[entry.objectId] else {
            throw SyncV2TypeError.missingEntity(key)
        }
        return bytes
    }
}
