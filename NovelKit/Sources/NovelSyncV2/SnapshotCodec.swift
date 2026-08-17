import Foundation
import NovelCore

public enum SnapshotCodec {
    public static func encode(_ model: SnapshotModel, parents: [SnapshotID] = []) throws -> EncodedSnapshot {
        var objects: [ObjectID: Data] = [:]
        var entries: [SnapshotEntry] = []
        func add(_ key: String, _ type: SnapshotEntry.ContentType, _ data: Data) throws {
            let id = ObjectID(data: data)
            objects[id] = data
            entries.append(SnapshotEntry(byteCount: data.count, contentType: type, entityKey: key, objectId: id))
        }
        let documentDate = try dateString(model.documentCreatedAt)
        let documentID = DocumentID(model.document.id)
        try add("work/document", .entityJSON, CanonicalJSON.object([
            ("documentCreatedAt", .string(documentDate)), ("documentId", .string(documentID.description))
        ]))
        try add("work/title", .entityJSON, value(model.document.title))
        try add("work/synopsis", .entityJSON, value(model.document.synopsis))
        try add("work/chapter-order", .entityJSON, ids(model.document.chapters.map { $0.id.rawValue.uuidString.lowercased() }))
        try add("work/character-order", .entityJSON, ids(model.document.characters.map { $0.id.rawValue.uuidString.lowercased() }))
        try add("work/plot-card-order", .entityJSON, ids(model.document.plotCards.map { $0.id.rawValue.uuidString.lowercased() }))
        try add("work/flag-order", .entityJSON, ids(model.document.flags.map { $0.id.rawValue.uuidString.lowercased() }))
        try add("work/world-note-order", .entityJSON, ids(model.document.worldNotes.map { $0.id.rawValue.uuidString.lowercased() }))
        try add("work/attachment-order", .entityJSON, ids(model.attachments.map { $0.attachmentId.uuidString.lowercased() }))
        for chapter in model.document.chapters {
            let chapterID = chapter.id.rawValue.uuidString.lowercased()
            try add("chapter/\(chapterID)/title", .entityJSON, value(chapter.title))
            try add("chapter/\(chapterID)/episode-order", .entityJSON, ids(chapter.episodes.map { $0.id.rawValue.uuidString.lowercased() }))
            for episode in chapter.episodes {
                let episodeID = episode.id.rawValue.uuidString.lowercased()
                try add("episode/\(episodeID)/title", .entityJSON, value(episode.title))
                try add("episode/\(episodeID)/body", .entityJSON, value(episode.content))
                try add("episode/\(episodeID)/memo", .entityJSON, value(episode.memo))
            }
        }
        for character in model.document.characters {
            try add("character/\(character.id.rawValue.uuidString.lowercased())", .entityJSON, characterPayload(character))
        }
        for card in model.document.plotCards {
            try add("plot-card/\(card.id.rawValue.uuidString.lowercased())", .entityJSON, plotCardPayload(card))
        }
        for flag in model.document.flags {
            try add("flag/\(flag.id.rawValue.uuidString.lowercased())", .entityJSON, flagPayload(flag))
        }
        for note in model.document.worldNotes {
            try add("world-note/\(note.id.rawValue.uuidString.lowercased())", .entityJSON, worldNotePayload(note))
        }
        for attachment in model.attachments {
            let id = attachment.attachmentId.uuidString.lowercased()
            try add("attachment/\(id)/metadata", .entityJSON, CanonicalJSON.object([
                ("attachmentId", .string(id)), ("byteCount", .number(Int64(attachment.bytes.count))), ("fileName", .string(attachment.fileName))
            ]))
            try add("attachment/\(id)/bytes", .octetStream, attachment.bytes)
        }
        let manifest = SnapshotManifest(workId: model.workId, parentSnapshotIds: parents, entries: entries.sorted { $0.entityKey < $1.entityKey })
        try SnapshotValidator.validate(manifest)
        let manifestBytes = try CanonicalJSON.encode(manifest)
        return EncodedSnapshot(manifest: manifest, manifestBytes: manifestBytes, objects: objects)
    }

    public static func decode(manifestBytes: Data, objects: [ObjectID: Data]) throws -> SnapshotModel {
        let manifest = try SnapshotValidator.validate(manifestBytes: manifestBytes)
        let encoded = EncodedSnapshot(manifest: manifest, manifestBytes: manifestBytes, objects: objects)
        try SnapshotValidator.validateObjects(encoded)
        let byKey = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.entityKey, $0) })
        func data(_ key: String) throws -> Data {
            guard let entry = byKey[key], let bytes = objects[entry.objectId] else { throw SyncV2TypeError.missingEntity(key) }
            return bytes
        }
        let documentInfo = try fields(data("work/document"), allowed: ["documentCreatedAt", "documentId"])
        guard let documentID = try UUID(uuidString: string(documentInfo, "documentId")) else { throw SyncV2TypeError.invalidUUID }
        let createdAt = try parseDate(string(documentInfo, "documentCreatedAt"))
        let chapterIDs = try order(data("work/chapter-order"))
        let characterIDs = try order(data("work/character-order"))
        let plotIDs = try order(data("work/plot-card-order"))
        let flagIDs = try order(data("work/flag-order"))
        let worldIDs = try order(data("work/world-note-order"))
        let attachmentIDs = try order(data("work/attachment-order"))
        var chapters: [Chapter] = []
        var ownedEpisodes = Set<String>()
        var expected = Set<String>(["work/document", "work/title", "work/synopsis", "work/chapter-order", "work/character-order", "work/plot-card-order", "work/flag-order", "work/world-note-order", "work/attachment-order"])
        for chapterID in chapterIDs {
            let chapterPrefix = "chapter/\(chapterID)"
            let episodeIDs = try order(data("\(chapterPrefix)/episode-order"))
            expected.insert("\(chapterPrefix)/title"); expected.insert("\(chapterPrefix)/episode-order")
            var episodes: [Episode] = []
            for episodeID in episodeIDs {
                guard ownedEpisodes.insert(episodeID).inserted else { throw SyncV2TypeError.referenceViolation("episode ownership") }
                let prefix = "episode/\(episodeID)"
                let title = try valueString(data("\(prefix)/title")); let body = try valueString(data("\(prefix)/body")); let memo = try valueString(data("\(prefix)/memo"))
                expected.formUnion(["\(prefix)/title", "\(prefix)/body", "\(prefix)/memo"])
                guard let eid = UUID(uuidString: episodeID) else { throw SyncV2TypeError.invalidUUID }
                episodes.append(Episode(id: EpisodeID(rawValue: eid), title: title, content: body, memo: memo))
            }
            guard let cid = UUID(uuidString: chapterID) else { throw SyncV2TypeError.invalidUUID }
            try chapters.append(Chapter(id: ChapterID(rawValue: cid), title: valueString(data("\(chapterPrefix)/title")), episodes: episodes))
        }
        var characters: [Character] = []
        for id in characterIDs {
            expected.insert("character/\(id)")
            let character = try decodeCharacter(data("character/\(id)"))
            guard character.id.rawValue.uuidString.lowercased() == id else { throw SyncV2TypeError.referenceViolation(id) }
            characters.append(character)
        }
        var cards: [PlotCard] = []
        for id in plotIDs {
            expected.insert("plot-card/\(id)")
            let card = try decodePlotCard(data("plot-card/\(id)"))
            guard card.id.rawValue.uuidString.lowercased() == id, card.chapterID == nil || chapterIDs.contains(card.chapterID!.rawValue.uuidString.lowercased()) else { throw SyncV2TypeError.referenceViolation(id) }
            cards.append(card)
        }
        var flags: [Flag] = []
        for id in flagIDs {
            expected.insert("flag/\(id)")
            let flag = try decodeFlag(data("flag/\(id)"))
            guard flag.id.rawValue.uuidString.lowercased() == id,
                  flag.plantedChapterID == nil || chapterIDs.contains(flag.plantedChapterID!.rawValue.uuidString.lowercased()),
                  flag.resolvedChapterID == nil || chapterIDs.contains(flag.resolvedChapterID!.rawValue.uuidString.lowercased()) else { throw SyncV2TypeError.referenceViolation(id) }
            flags.append(flag)
        }
        var notes: [WorldNote] = []
        for id in worldIDs {
            expected.insert("world-note/\(id)")
            let note = try decodeWorldNote(data("world-note/\(id)"))
            guard note.id.rawValue.uuidString.lowercased() == id else { throw SyncV2TypeError.referenceViolation(id) }
            notes.append(note)
        }
        var attachments: [SyncAttachment] = []
        for id in attachmentIDs {
            expected.insert("attachment/\(id)/metadata"); expected.insert("attachment/\(id)/bytes")
            let meta = try fields(data("attachment/\(id)/metadata"), allowed: ["attachmentId", "byteCount", "fileName"])
            guard try string(meta, "attachmentId") == id, let uuid = UUID(uuidString: id), try int(meta, "byteCount") >= 0 else { throw SyncV2TypeError.referenceViolation(id) }
            let bytes = try data("attachment/\(id)/bytes")
            let expectedBytes = try int(meta, "byteCount")
            guard bytes.count == expectedBytes else { throw SyncV2TypeError.byteCountMismatch }
            try attachments.append(SyncAttachment(attachmentId: uuid, fileName: string(meta, "fileName"), bytes: bytes))
        }
        guard Set(byKey.keys) == expected else { throw SyncV2TypeError.referenceViolation("entity closure") }
        let document = try NovelDocument(id: documentID, title: valueString(data("work/title")), synopsis: valueString(data("work/synopsis")), chapters: chapters, characters: characters, plotCards: cards, flags: flags, worldNotes: notes)
        return SnapshotModel(workId: manifest.workId, document: document, documentCreatedAt: createdAt, attachments: attachments)
    }

    private static func value(_ string: String) -> Data {
        CanonicalJSON.object([("value", .string(string))])
    }

    private static func ids(_ values: [String]) -> Data {
        CanonicalJSON.object([("ids", .array(values.map { .string($0) }))])
    }

    private static func optional(_ value: String?) -> CanonicalJSON.Value {
        value.map { .string($0) } ?? .null
    }

    private static func characterPayload(_ c: Character) -> Data {
        CanonicalJSON.object([
            ("age", optional(c.age)), ("appearance", optional(c.appearance)), ("background", optional(c.background)), ("colorHex", optional(c.colorHex)), ("firstPerson", optional(c.firstPerson)), ("gender", optional(c.gender)), ("id", .string(c.id.rawValue.uuidString.lowercased())), ("kana", .string(c.kana)), ("memo", .string(c.memo)), ("name", .string(c.name)), ("personality", optional(c.personality)), ("role", optional(c.role)), ("secondPerson", optional(c.secondPerson)), ("speechStyle", optional(c.speechStyle))
        ])
    }

    private static func plotCardPayload(_ c: PlotCard) -> Data {
        CanonicalJSON.object([("chapterId", optional(c.chapterID?.rawValue.uuidString.lowercased())), ("id", .string(c.id.rawValue.uuidString.lowercased())), ("memo", .string(c.memo)), ("title", .string(c.title))])
    }

    private static func flagPayload(_ f: Flag) -> Data {
        CanonicalJSON.object([("id", .string(f.id.rawValue.uuidString.lowercased())), ("isResolved", .bool(f.isResolved)), ("note", .string(f.note)), ("plantedChapterId", optional(f.plantedChapterID?.rawValue.uuidString.lowercased())), ("resolvedChapterId", optional(f.resolvedChapterID?.rawValue.uuidString.lowercased())), ("title", .string(f.title))])
    }

    private static func worldNotePayload(_ n: WorldNote) -> Data {
        CanonicalJSON.object([("content", .string(n.content)), ("id", .string(n.id.rawValue.uuidString.lowercased())), ("title", .string(n.title))])
    }

    private static func fields(_ data: Data, allowed: Set<String>) throws -> [String: CanonicalJSON.Value] {
        guard case let .object(pairs) = try CanonicalJSON.parseObject(data) else { throw SyncV2TypeError.schemaViolation("object") }
        let result = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard Set(result.keys) == allowed else { throw SyncV2TypeError.schemaViolation("fields") }
        return result
    }

    private static func string(_ fields: [String: CanonicalJSON.Value], _ key: String) throws -> String {
        guard case let .string(value) = fields[key] else { throw SyncV2TypeError.schemaViolation(key) }; return value
    }

    private static func int(_ fields: [String: CanonicalJSON.Value], _ key: String) throws -> Int {
        guard case let .number(value) = fields[key], value >= 0, value <= Int64(Int.max) else { throw SyncV2TypeError.schemaViolation(key) }; return Int(value)
    }

    private static func valueString(_ data: Data) throws -> String {
        try string(fields(data, allowed: ["value"]), "value")
    }

    private static func order(_ data: Data) throws -> [String] {
        guard case let .object(pairs) = try CanonicalJSON.parseObject(data), let value = Dictionary(pairs, uniquingKeysWith: { first, _ in first })["ids"], case let .array(ids) = value else { throw SyncV2TypeError.schemaViolation("ids") }
        let strings = try ids.map { guard case let .string(id) = $0, UUID(uuidString: id) != nil, id == id.lowercased() else { throw SyncV2TypeError.invalidUUID }; return id }
        guard Set(strings).count == strings.count else { throw SyncV2TypeError.referenceViolation("duplicate order") }
        return strings
    }

    private static func uuid(_ value: CanonicalJSON.Value?, _: String) throws -> UUID? {
        if case .null = value {
            return nil
        }; guard case let .string(s) = value, let id = UUID(uuidString: s), s == s.lowercased() else { throw SyncV2TypeError.invalidUUID }; return id
    }

    private static func decodeCharacter(_ data: Data) throws -> Character {
        let f = try fields(data, allowed: ["age", "appearance", "background", "colorHex", "firstPerson", "gender", "id", "kana", "memo", "name", "personality", "role", "secondPerson", "speechStyle"])
        guard let id = try uuid(f["id"], "id") else { throw SyncV2TypeError.invalidUUID }
        func opt(_ key: String) throws -> String? {
            if case .null = f[key] {
                return nil
            }; return try string(f, key)
        }
        let color = try opt("colorHex"); if let color, color.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil {
            throw SyncV2TypeError.schemaViolation("colorHex")
        }
        return try Character(id: CharacterID(rawValue: id), name: string(f, "name"), kana: string(f, "kana"), memo: string(f, "memo"), colorHex: color, role: opt("role"), age: opt("age"), gender: opt("gender"), firstPerson: opt("firstPerson"), secondPerson: opt("secondPerson"), speechStyle: opt("speechStyle"), appearance: opt("appearance"), personality: opt("personality"), background: opt("background"))
    }

    private static func decodePlotCard(_ data: Data) throws -> PlotCard {
        let f = try fields(data, allowed: ["chapterId", "id", "memo", "title"]); guard let id = try uuid(f["id"], "id") else { throw SyncV2TypeError.invalidUUID }; return try PlotCard(id: PlotCardID(rawValue: id), title: string(f, "title"), memo: string(f, "memo"), chapterID: uuid(f["chapterId"], "chapterId").map(ChapterID.init(rawValue:)))
    }

    private static func decodeFlag(_ data: Data) throws -> Flag {
        let f = try fields(data, allowed: ["id", "isResolved", "note", "plantedChapterId", "resolvedChapterId", "title"]); guard let id = try uuid(f["id"], "id"), case let .bool(resolved) = f["isResolved"] else { throw SyncV2TypeError.schemaViolation("flag") }; return try Flag(id: FlagID(rawValue: id), title: string(f, "title"), note: string(f, "note"), isResolved: resolved, plantedChapterID: uuid(f["plantedChapterId"], "plantedChapterId").map(ChapterID.init(rawValue:)), resolvedChapterID: uuid(f["resolvedChapterId"], "resolvedChapterId").map(ChapterID.init(rawValue:)))
    }

    private static func decodeWorldNote(_ data: Data) throws -> WorldNote {
        let f = try fields(data, allowed: ["content", "id", "title"]); guard let id = try uuid(f["id"], "id") else { throw SyncV2TypeError.invalidUUID }; return try WorldNote(id: WorldNoteID(rawValue: id), title: string(f, "title"), content: string(f, "content"))
    }

    private static func dateString(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]; let result = formatter.string(from: date); guard result.hasSuffix("Z") else { throw SyncV2TypeError.schemaViolation("date") }; return result
    }

    private static func parseDate(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]; guard let date = formatter.date(from: string), try dateString(date) == string else { throw SyncV2TypeError.schemaViolation("date") }; return date
    }
}
