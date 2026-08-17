import Foundation
import NovelCore

extension SnapshotCodec {
    static func fields(
        _ data: Data,
        allowed: Set<String>
    ) throws -> [String: CanonicalJSON.Value] {
        guard case let .object(pairs) = try CanonicalJSON.parseObject(data) else {
            throw SyncV2TypeError.schemaViolation("object")
        }
        let result = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard Set(result.keys) == allowed else {
            throw SyncV2TypeError.schemaViolation("fields")
        }
        return result
    }

    static func string(
        _ fields: [String: CanonicalJSON.Value],
        _ key: String
    ) throws -> String {
        guard case let .string(value) = fields[key] else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        return value
    }

    static func int(
        _ fields: [String: CanonicalJSON.Value],
        _ key: String
    ) throws -> Int {
        guard case let .number(value) = fields[key],
              value >= 0,
              value <= Int64(Int.max) else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        return Int(value)
    }

    static func valueString(_ data: Data) throws -> String {
        try string(fields(data, allowed: ["value"]), "value")
    }

    static func order(_ data: Data) throws -> [String] {
        guard case let .object(pairs) = try CanonicalJSON.parseObject(data),
              let value = Dictionary(pairs, uniquingKeysWith: { first, _ in first })["ids"],
              case let .array(identifiers) = value else {
            throw SyncV2TypeError.schemaViolation("ids")
        }
        let strings = try identifiers.map { identifier -> String in
            guard case let .string(string) = identifier,
                  SyncV2UUID.parse(string) != nil else {
                throw SyncV2TypeError.invalidUUID
            }
            return string
        }
        guard Set(strings).count == strings.count else {
            throw SyncV2TypeError.referenceViolation("duplicate order")
        }
        return strings
    }

    static func uuid(_ value: CanonicalJSON.Value?, _: String) throws -> UUID? {
        if case .null = value {
            return nil
        }
        guard case let .string(string) = value,
              let identifier = SyncV2UUID.parse(string) else {
            throw SyncV2TypeError.invalidUUID
        }
        return identifier
    }

    static func decodeCharacter(_ data: Data) throws -> Character {
        let fields = try fields(data, allowed: characterFieldNames)
        guard let identifier = try uuid(fields["id"], "id") else {
            throw SyncV2TypeError.invalidUUID
        }
        let color = try optionalString(fields, key: "colorHex")
        if let color,
           color.range(
               of: #"^#[0-9A-Fa-f]{6}$"#,
               options: .regularExpression
           ) == nil {
            throw SyncV2TypeError.schemaViolation("colorHex")
        }
        return try Character(
            id: CharacterID(rawValue: identifier),
            name: string(fields, "name"),
            kana: string(fields, "kana"),
            memo: string(fields, "memo"),
            colorHex: color,
            role: optionalString(fields, key: "role"),
            age: optionalString(fields, key: "age"),
            gender: optionalString(fields, key: "gender"),
            firstPerson: optionalString(fields, key: "firstPerson"),
            secondPerson: optionalString(fields, key: "secondPerson"),
            speechStyle: optionalString(fields, key: "speechStyle"),
            appearance: optionalString(fields, key: "appearance"),
            personality: optionalString(fields, key: "personality"),
            background: optionalString(fields, key: "background")
        )
    }

    private static let characterFieldNames: Set<String> = [
        "age",
        "appearance",
        "background",
        "colorHex",
        "firstPerson",
        "gender",
        "id",
        "kana",
        "memo",
        "name",
        "personality",
        "role",
        "secondPerson",
        "speechStyle"
    ]

    private static func optionalString(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws -> String? {
        if case .null = fields[key] {
            return nil
        }
        return try string(fields, key)
    }

    static func decodePlotCard(_ data: Data) throws -> PlotCard {
        let fields = try fields(
            data,
            allowed: ["chapterId", "id", "memo", "title"]
        )
        guard let identifier = try uuid(fields["id"], "id") else {
            throw SyncV2TypeError.invalidUUID
        }
        return try PlotCard(
            id: PlotCardID(rawValue: identifier),
            title: string(fields, "title"),
            memo: string(fields, "memo"),
            chapterID: uuid(fields["chapterId"], "chapterId").map(ChapterID.init(rawValue:))
        )
    }

    static func decodeFlag(_ data: Data) throws -> Flag {
        let fields = try fields(
            data,
            allowed: [
                "id",
                "isResolved",
                "note",
                "plantedChapterId",
                "resolvedChapterId",
                "title"
            ]
        )
        guard let identifier = try uuid(fields["id"], "id"),
              case let .bool(resolved) = fields["isResolved"] else {
            throw SyncV2TypeError.schemaViolation("flag")
        }
        return try Flag(
            id: FlagID(rawValue: identifier),
            title: string(fields, "title"),
            note: string(fields, "note"),
            isResolved: resolved,
            plantedChapterID: uuid(
                fields["plantedChapterId"],
                "plantedChapterId"
            ).map(ChapterID.init(rawValue:)),
            resolvedChapterID: uuid(
                fields["resolvedChapterId"],
                "resolvedChapterId"
            ).map(ChapterID.init(rawValue:))
        )
    }

    static func decodeWorldNote(_ data: Data) throws -> WorldNote {
        let fields = try fields(
            data,
            allowed: ["content", "id", "title"]
        )
        guard let identifier = try uuid(fields["id"], "id") else {
            throw SyncV2TypeError.invalidUUID
        }
        return try WorldNote(
            id: WorldNoteID(rawValue: identifier),
            title: string(fields, "title"),
            content: string(fields, "content")
        )
    }

    static func chapterReference(
        _ chapterID: ChapterID?,
        belongsTo identifiers: Set<String>
    ) -> Bool {
        guard let chapterID else {
            return true
        }
        return identifiers.contains(chapterID.rawValue.uuidString.lowercased())
    }

    static func parseDate(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime
        ]
        guard let date = formatter.date(from: string),
              try dateString(date) == string else {
            throw SyncV2TypeError.schemaViolation("date")
        }
        return date
    }
}
