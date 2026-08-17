import Foundation

public struct EntityKey: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw SyncV2TypeError.invalidEntityKey }
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    static func isValid(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let uuid = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        let dynamic = "(?:" + uuid + ")"
        let patterns = [
            #"^work/(document|title|synopsis|chapter-order|character-order|plot-card-order|flag-order|world-note-order|attachment-order)$"#,
            "^chapter/" + dynamic + #"/(title|episode-order)$"#,
            "^episode/" + dynamic + #"/(title|body|memo)$"#,
            "^character/" + dynamic + "$",
            "^plot-card/" + dynamic + "$",
            "^flag/" + dynamic + "$",
            "^world-note/" + dynamic + "$",
            "^attachment/" + dynamic + #"/(metadata|bytes)$"#
        ]
        return patterns.contains { key.range(of: $0, options: .regularExpression) != nil }
    }

    var id: String? {
        let p = rawValue.split(separator: "/")
        guard p.count >= 2 else { return nil }
        if p[0] == "work" {
            return nil
        }
        return p[1].count == 36 ? String(p[1]) : nil
    }
}

public enum SnapshotValidator {
    public static let entityJSONContentType = SnapshotEntry.ContentType.entityJSON
    public static let octetStreamContentType = SnapshotEntry.ContentType.octetStream

    public static func validate(_ manifest: SnapshotManifest) throws {
        guard manifest.schemaVersion == 2,
              manifest.entries.count <= 100_000 else { throw SyncV2TypeError.invalidManifest }
        guard manifest.parentSnapshotIds.count <= 2 else { throw SyncV2TypeError.invalidManifest }
        let parents = manifest.parentSnapshotIds.map(\.rawValue)
        guard parents == parents.sorted(), Set(parents).count == parents.count else {
            throw SyncV2TypeError.invalidManifest
        }
        let keys = manifest.entries.map(\.entityKey)
        guard keys == keys.sorted(), Set(keys).count == keys.count else { throw SyncV2TypeError.invalidManifest }
        for entry in manifest.entries {
            guard entry.byteCount >= 0, entry.byteCount <= 262_144_000 else { throw SyncV2TypeError.invalidManifest }
            _ = try EntityKey(entry.entityKey)
            if entry.contentType == .octetStream {
                guard entry.entityKey.hasSuffix("/bytes") else { throw SyncV2TypeError.schemaViolation(entry.entityKey) }
            } else {
                guard !entry.entityKey.hasSuffix("/bytes") else { throw SyncV2TypeError.schemaViolation(entry.entityKey) }
            }
        }
        let required = ["work/document", "work/title", "work/synopsis", "work/chapter-order", "work/character-order", "work/plot-card-order", "work/flag-order", "work/world-note-order", "work/attachment-order"]
        for key in required where !keys.contains(key) {
            throw SyncV2TypeError.missingEntity(key)
        }
    }

    public static func validate(manifestBytes: Data) throws -> SnapshotManifest {
        let value = try CanonicalJSON.parseObject(manifestBytes)
        let json = try JSONDecoder().decode(SnapshotManifest.self, from: manifestBytes)
        try validate(json)
        guard case let .object(fields) = value,
              Set(fields.map(\.0)) == Set(["entries", "parentSnapshotIds", "schemaVersion", "workId"]) else {
            throw SyncV2TypeError.invalidManifest
        }
        guard let entries = fields.first(where: { $0.0 == "entries" })?.1,
              case let .array(rawEntries) = entries else { throw SyncV2TypeError.invalidManifest }
        for rawEntry in rawEntries {
            guard case let .object(entryFields) = rawEntry,
                  Set(entryFields.map(\.0)) == Set(["byteCount", "contentType", "entityKey", "objectId"]) else {
                throw SyncV2TypeError.invalidManifest
            }
        }
        return json
    }

    public static func validateObjects(_ encoded: EncodedSnapshot) throws {
        let decodedManifest = try validate(manifestBytes: encoded.manifestBytes)
        guard decodedManifest == encoded.manifest else { throw SyncV2TypeError.invalidManifest }
        for entry in encoded.manifest.entries {
            guard let data = encoded.objects[entry.objectId] else { throw SyncV2TypeError.missingEntity(entry.entityKey) }
            guard data.count == entry.byteCount else { throw SyncV2TypeError.byteCountMismatch }
            guard ObjectID(data: data) == entry.objectId else { throw SyncV2TypeError.digestMismatch }
            if entry.contentType == .entityJSON {
                try validateEntity(data, for: entry.entityKey)
            }
        }
    }

    private static let maxStringLength = 1_048_576

    private static func validateEntity(_ data: Data, for key: String) throws {
        guard case let .object(pairs) = try CanonicalJSON.parseObject(data) else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        let fields = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        if key == "work/document" {
            try require(fields, ["documentCreatedAt", "documentId"], key)
            guard case let .string(date) = fields["documentCreatedAt"],
                  date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#, options: .regularExpression) != nil,
                  case let .string(documentID) = fields["documentId"], SyncV2UUID.parse(documentID) != nil else {
                throw SyncV2TypeError.schemaViolation(key)
            }
            return
        }
        if key == "work/title" || key == "work/synopsis" || key.hasSuffix("/title") || key.hasSuffix("/body") || key.hasSuffix("/memo") {
            try require(fields, ["value"], key)
            try string(fields["value"], key, max: maxStringLength)
            return
        }
        if key.hasSuffix("-order") {
            try require(fields, ["ids"], key)
            guard case let .array(ids) = fields["ids"], ids.count <= 100_000 else {
                throw SyncV2TypeError.schemaViolation(key)
            }
            var seen = Set<String>()
            for id in ids {
                guard case let .string(value) = id, SyncV2UUID.parse(value) != nil, seen.insert(value).inserted else {
                    throw SyncV2TypeError.schemaViolation(key)
                }
            }
            return
        }
        if key.hasPrefix("character/") {
            try require(fields, ["age", "appearance", "background", "colorHex", "firstPerson", "gender", "id", "kana", "memo", "name", "personality", "role", "secondPerson", "speechStyle"], key)
            try uuid(fields["id"], key)
            try requiredString(fields, ["kana", "memo", "name"], key)
            try optionalStrings(fields, ["age", "appearance", "background", "firstPerson", "gender", "personality", "role", "secondPerson", "speechStyle"], key)
            if case let .string(color) = fields["colorHex"] {
                guard color.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else { throw SyncV2TypeError.schemaViolation(key) }
            } else if case .null = fields["colorHex"] {
            } else {
                throw SyncV2TypeError.schemaViolation(key)
            }
            return
        }
        if key.hasPrefix("plot-card/") {
            try require(fields, ["chapterId", "id", "memo", "title"], key)
            try uuid(fields["id"], key); try optionalUUID(fields["chapterId"], key)
            try requiredString(fields, ["memo", "title"], key); return
        }
        if key.hasPrefix("flag/") {
            try require(fields, ["id", "isResolved", "note", "plantedChapterId", "resolvedChapterId", "title"], key)
            try uuid(fields["id"], key); try optionalUUID(fields["plantedChapterId"], key); try optionalUUID(fields["resolvedChapterId"], key)
            guard case .bool = fields["isResolved"] else { throw SyncV2TypeError.schemaViolation(key) }
            try requiredString(fields, ["note", "title"], key); return
        }
        if key.hasPrefix("world-note/") {
            try require(fields, ["content", "id", "title"], key); try uuid(fields["id"], key)
            try requiredString(fields, ["content", "title"], key); return
        }
        if key.hasSuffix("/metadata") {
            try require(fields, ["attachmentId", "byteCount", "fileName"], key); try uuid(fields["attachmentId"], key)
            guard case let .number(count) = fields["byteCount"], count >= 0, count <= 262_144_000 else { throw SyncV2TypeError.schemaViolation(key) }
            try string(fields["fileName"], key, min: 1, max: 255); return
        }
        throw SyncV2TypeError.schemaViolation(key)
    }

    private static func require(_ fields: [String: CanonicalJSON.Value], _ expected: Set<String>, _ key: String) throws {
        guard Set(fields.keys) == expected else { throw SyncV2TypeError.schemaViolation(key) }
    }

    private static func string(_ value: CanonicalJSON.Value?, _ key: String, min: Int = 0, max: Int) throws {
        guard case let .string(value) = value,
              value.unicodeScalars.count >= min,
              value.unicodeScalars.count <= max else { throw SyncV2TypeError.schemaViolation(key) }
    }

    private static func requiredString(_ fields: [String: CanonicalJSON.Value], _ keys: [String], _ key: String) throws {
        for field in keys {
            try string(fields[field], key, max: maxStringLength)
        }
    }

    private static func optionalStrings(_ fields: [String: CanonicalJSON.Value], _ keys: [String], _ key: String) throws {
        for field in keys {
            guard case .null = fields[field] else { try string(fields[field], key, max: maxStringLength); continue }
        }
    }

    private static func uuid(_ value: CanonicalJSON.Value?, _ key: String) throws {
        guard case let .string(value) = value, SyncV2UUID.parse(value) != nil else { throw SyncV2TypeError.schemaViolation(key) }
    }

    private static func optionalUUID(_ value: CanonicalJSON.Value?, _ key: String) throws {
        if case .null = value {
            return
        }
        try uuid(value, key)
    }
}
