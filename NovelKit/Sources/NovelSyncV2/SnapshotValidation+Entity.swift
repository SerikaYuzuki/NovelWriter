import Foundation

extension SnapshotValidator {
    static let maxStringLength = 1_048_576

    static func validateEntity(_ data: Data, for key: String) throws {
        guard data.count <= SnapshotSyncV2Limits.maxStructuredEntityBytes,
              case let .object(pairs) = try CanonicalJSON.parseObject(
                  data,
                  maxBytes: SnapshotSyncV2Limits.maxStructuredEntityBytes
              ) else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        let fields = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        if key == "work/document" {
            try validateDocument(fields, key: key)
        } else if isTextEntity(key) {
            try validateText(fields, key: key)
        } else if key.hasSuffix("-order") {
            try validateOrder(fields, key: key)
        } else if key.hasPrefix("character/") {
            try validateCharacter(fields, key: key)
        } else if key.hasPrefix("plot-card/") {
            try validatePlotCard(fields, key: key)
        } else if key.hasPrefix("flag/") {
            try validateFlag(fields, key: key)
        } else if key.hasPrefix("world-note/") {
            try validateWorldNote(fields, key: key)
        } else if key.hasSuffix("/metadata") {
            try validateAttachmentMetadata(fields, key: key)
        } else {
            throw SyncV2TypeError.schemaViolation(key)
        }
    }

    private static func isTextEntity(_ key: String) -> Bool {
        key == "work/title" ||
            key == "work/synopsis" ||
            key.hasSuffix("/title") ||
            key.hasSuffix("/body") ||
            key.hasSuffix("/memo")
    }

    private static func validateDocument(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(fields, ["documentCreatedAt", "documentId"], key)
        guard case let .string(date) = fields["documentCreatedAt"],
              date.range(
                  of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#,
                  options: .regularExpression
              ) != nil,
              case let .string(documentID) = fields["documentId"],
              SyncV2UUID.parse(documentID) != nil else {
            throw SyncV2TypeError.schemaViolation(key)
        }
    }

    private static func validateText(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(fields, ["value"], key)
        try string(fields["value"], key, max: maxStringLength)
    }

    private static func validateOrder(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(fields, ["ids"], key)
        guard case let .array(identifiers) = fields["ids"],
              identifiers.count <= SnapshotSyncV2Limits.maxEntries else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        var seen = Set<String>()
        for identifier in identifiers {
            guard case let .string(value) = identifier,
                  SyncV2UUID.parse(value) != nil,
                  seen.insert(value).inserted else {
                throw SyncV2TypeError.schemaViolation(key)
            }
        }
    }

    private static func validateCharacter(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(
            fields,
            [
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
            ],
            key
        )
        try uuid(fields["id"], key)
        try requiredString(fields, ["kana", "memo", "name"], key)
        try optionalStrings(
            fields,
            [
                "age",
                "appearance",
                "background",
                "firstPerson",
                "gender",
                "personality",
                "role",
                "secondPerson",
                "speechStyle"
            ],
            key
        )
        if case let .string(color) = fields["colorHex"] {
            guard color.range(
                of: #"^#[0-9A-Fa-f]{6}$"#,
                options: .regularExpression
            ) != nil else {
                throw SyncV2TypeError.schemaViolation(key)
            }
        } else if case .null = fields["colorHex"] {
        } else {
            throw SyncV2TypeError.schemaViolation(key)
        }
    }

    private static func validatePlotCard(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(fields, ["chapterId", "id", "memo", "title"], key)
        try uuid(fields["id"], key)
        try optionalUUID(fields["chapterId"], key)
        try requiredString(fields, ["memo", "title"], key)
    }

    private static func validateFlag(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(
            fields,
            [
                "id",
                "isResolved",
                "note",
                "plantedChapterId",
                "resolvedChapterId",
                "title"
            ],
            key
        )
        try uuid(fields["id"], key)
        try optionalUUID(fields["plantedChapterId"], key)
        try optionalUUID(fields["resolvedChapterId"], key)
        guard case .bool = fields["isResolved"] else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        try requiredString(fields, ["note", "title"], key)
    }

    private static func validateWorldNote(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(fields, ["content", "id", "title"], key)
        try uuid(fields["id"], key)
        try requiredString(fields, ["content", "title"], key)
    }

    private static func validateAttachmentMetadata(
        _ fields: [String: CanonicalJSON.Value],
        key: String
    ) throws {
        try require(fields, ["attachmentId", "byteCount", "fileName"], key)
        try uuid(fields["attachmentId"], key)
        guard case let .number(count) = fields["byteCount"],
              count >= 0,
              count <= SnapshotSyncV2Limits.maxObjectBytes else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        try string(fields["fileName"], key, min: 1, max: 255)
    }

    private static func require(
        _ fields: [String: CanonicalJSON.Value],
        _ expected: Set<String>,
        _ key: String
    ) throws {
        guard Set(fields.keys) == expected else {
            throw SyncV2TypeError.schemaViolation(key)
        }
    }

    private static func string(
        _ value: CanonicalJSON.Value?,
        _ key: String,
        min: Int = 0,
        max: Int
    ) throws {
        guard case let .string(value) = value,
              value.unicodeScalars.count >= min,
              value.unicodeScalars.count <= max else {
            throw SyncV2TypeError.schemaViolation(key)
        }
    }

    private static func requiredString(
        _ fields: [String: CanonicalJSON.Value],
        _ keys: [String],
        _ key: String
    ) throws {
        for field in keys {
            try string(fields[field], key, max: maxStringLength)
        }
    }

    private static func optionalStrings(
        _ fields: [String: CanonicalJSON.Value],
        _ keys: [String],
        _ key: String
    ) throws {
        for field in keys {
            guard case .null = fields[field] else {
                try string(fields[field], key, max: maxStringLength)
                continue
            }
        }
    }

    private static func uuid(
        _ value: CanonicalJSON.Value?,
        _ key: String
    ) throws {
        guard case let .string(value) = value,
              SyncV2UUID.parse(value) != nil else {
            throw SyncV2TypeError.schemaViolation(key)
        }
    }

    private static func optionalUUID(
        _ value: CanonicalJSON.Value?,
        _ key: String
    ) throws {
        if case .null = value {
            return
        }
        try uuid(value, key)
    }
}
