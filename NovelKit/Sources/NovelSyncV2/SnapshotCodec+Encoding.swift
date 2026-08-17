import Foundation
import NovelCore

struct SnapshotEncodingContext {
    private var objects: [ObjectID: Data] = [:]
    private var entries: [SnapshotEntry] = []

    mutating func encode(
        _ model: SnapshotModel,
        parents: [SnapshotID]
    ) throws -> EncodedSnapshot {
        try addWorkMetadata(model)
        addChapters(model.document.chapters)
        addDocumentCollections(model.document)
        addAttachments(model.attachments)

        let manifest = SnapshotManifest(
            workId: model.workId,
            parentSnapshotIds: parents,
            entries: entries.sorted { $0.entityKey < $1.entityKey }
        )
        try SnapshotValidator.validate(manifest)
        let manifestBytes = try CanonicalJSON.encode(manifest)
        return EncodedSnapshot(
            manifest: manifest,
            manifestBytes: manifestBytes,
            objects: objects
        )
    }

    private mutating func addWorkMetadata(_ model: SnapshotModel) throws {
        let documentDate = try SnapshotCodec.dateString(model.documentCreatedAt)
        let documentID = DocumentID(model.document.id)
        add(
            "work/document",
            .entityJSON,
            CanonicalJSON.object([
                ("documentCreatedAt", .string(documentDate)),
                ("documentId", .string(documentID.description))
            ])
        )
        add("work/title", .entityJSON, SnapshotCodec.value(model.document.title))
        add("work/synopsis", .entityJSON, SnapshotCodec.value(model.document.synopsis))
        add(
            "work/chapter-order",
            .entityJSON,
            SnapshotCodec.ids(model.document.chapters.map { $0.id.rawValue.uuidString.lowercased() })
        )
        add(
            "work/character-order",
            .entityJSON,
            SnapshotCodec.ids(model.document.characters.map { $0.id.rawValue.uuidString.lowercased() })
        )
        add(
            "work/plot-card-order",
            .entityJSON,
            SnapshotCodec.ids(model.document.plotCards.map { $0.id.rawValue.uuidString.lowercased() })
        )
        add(
            "work/flag-order",
            .entityJSON,
            SnapshotCodec.ids(model.document.flags.map { $0.id.rawValue.uuidString.lowercased() })
        )
        add(
            "work/world-note-order",
            .entityJSON,
            SnapshotCodec.ids(model.document.worldNotes.map { $0.id.rawValue.uuidString.lowercased() })
        )
        add(
            "work/attachment-order",
            .entityJSON,
            SnapshotCodec.ids(model.attachments.map { $0.attachmentId.uuidString.lowercased() })
        )
    }

    private mutating func addChapters(_ chapters: [Chapter]) {
        for chapter in chapters {
            let chapterID = chapter.id.rawValue.uuidString.lowercased()
            add(
                "chapter/\(chapterID)/title",
                .entityJSON,
                SnapshotCodec.value(chapter.title)
            )
            add(
                "chapter/\(chapterID)/episode-order",
                .entityJSON,
                SnapshotCodec.ids(chapter.episodes.map { $0.id.rawValue.uuidString.lowercased() })
            )
            for episode in chapter.episodes {
                addEpisode(episode)
            }
        }
    }

    private mutating func addEpisode(_ episode: Episode) {
        let episodeID = episode.id.rawValue.uuidString.lowercased()
        let prefix = "episode/\(episodeID)"
        add("\(prefix)/title", .entityJSON, SnapshotCodec.value(episode.title))
        add("\(prefix)/body", .entityJSON, SnapshotCodec.value(episode.content))
        add("\(prefix)/memo", .entityJSON, SnapshotCodec.value(episode.memo))
    }

    private mutating func addDocumentCollections(_ document: NovelDocument) {
        for character in document.characters {
            add(
                "character/\(character.id.rawValue.uuidString.lowercased())",
                .entityJSON,
                SnapshotCodec.characterPayload(character)
            )
        }
        for card in document.plotCards {
            add(
                "plot-card/\(card.id.rawValue.uuidString.lowercased())",
                .entityJSON,
                SnapshotCodec.plotCardPayload(card)
            )
        }
        for flag in document.flags {
            add(
                "flag/\(flag.id.rawValue.uuidString.lowercased())",
                .entityJSON,
                SnapshotCodec.flagPayload(flag)
            )
        }
        for note in document.worldNotes {
            add(
                "world-note/\(note.id.rawValue.uuidString.lowercased())",
                .entityJSON,
                SnapshotCodec.worldNotePayload(note)
            )
        }
    }

    private mutating func addAttachments(_ attachments: [SyncAttachment]) {
        for attachment in attachments {
            let attachmentID = attachment.attachmentId.uuidString.lowercased()
            add(
                "attachment/\(attachmentID)/metadata",
                .entityJSON,
                CanonicalJSON.object([
                    ("attachmentId", .string(attachmentID)),
                    ("byteCount", .number(Int64(attachment.bytes.count))),
                    ("fileName", .string(attachment.fileName))
                ])
            )
            add(
                "attachment/\(attachmentID)/bytes",
                .octetStream,
                attachment.bytes
            )
        }
    }

    private mutating func add(
        _ key: String,
        _ type: SnapshotEntry.ContentType,
        _ data: Data
    ) {
        let objectID = ObjectID(data: data)
        objects[objectID] = data
        entries.append(
            SnapshotEntry(
                byteCount: data.count,
                contentType: type,
                entityKey: key,
                objectId: objectID
            )
        )
    }
}

extension SnapshotCodec {
    static func value(_ string: String) -> Data {
        CanonicalJSON.object([("value", .string(string))])
    }

    static func ids(_ values: [String]) -> Data {
        CanonicalJSON.object([("ids", .array(values.map { .string($0) }))])
    }

    static func optional(_ value: String?) -> CanonicalJSON.Value {
        value.map { .string($0) } ?? .null
    }

    static func characterPayload(_ character: Character) -> Data {
        CanonicalJSON.object([
            ("age", optional(character.age)),
            ("appearance", optional(character.appearance)),
            ("background", optional(character.background)),
            ("colorHex", optional(character.colorHex)),
            ("firstPerson", optional(character.firstPerson)),
            ("gender", optional(character.gender)),
            ("id", .string(character.id.rawValue.uuidString.lowercased())),
            ("kana", .string(character.kana)),
            ("memo", .string(character.memo)),
            ("name", .string(character.name)),
            ("personality", optional(character.personality)),
            ("role", optional(character.role)),
            ("secondPerson", optional(character.secondPerson)),
            ("speechStyle", optional(character.speechStyle))
        ])
    }

    static func plotCardPayload(_ card: PlotCard) -> Data {
        CanonicalJSON.object([
            ("chapterId", optional(card.chapterID?.rawValue.uuidString.lowercased())),
            ("id", .string(card.id.rawValue.uuidString.lowercased())),
            ("memo", .string(card.memo)),
            ("title", .string(card.title))
        ])
    }

    static func flagPayload(_ flag: Flag) -> Data {
        CanonicalJSON.object([
            ("id", .string(flag.id.rawValue.uuidString.lowercased())),
            ("isResolved", .bool(flag.isResolved)),
            ("note", .string(flag.note)),
            ("plantedChapterId", optional(flag.plantedChapterID?.rawValue.uuidString.lowercased())),
            ("resolvedChapterId", optional(flag.resolvedChapterID?.rawValue.uuidString.lowercased())),
            ("title", .string(flag.title))
        ])
    }

    static func worldNotePayload(_ note: WorldNote) -> Data {
        CanonicalJSON.object([
            ("content", .string(note.content)),
            ("id", .string(note.id.rawValue.uuidString.lowercased())),
            ("title", .string(note.title))
        ])
    }

    static func dateString(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime
        ]
        let result = formatter.string(from: date)
        guard result.hasSuffix("Z") else {
            throw SyncV2TypeError.schemaViolation("date")
        }
        return result
    }
}
