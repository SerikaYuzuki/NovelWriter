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
        guard manifest.schemaVersion == 2 else { throw SyncV2TypeError.invalidManifest }
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
        guard case let .object(fields) = value, fields.count == 4 else { throw SyncV2TypeError.invalidManifest }
        return json
    }

    public static func validateObjects(_ encoded: EncodedSnapshot) throws {
        try validate(encoded.manifest)
        for entry in encoded.manifest.entries {
            guard let data = encoded.objects[entry.objectId] else { throw SyncV2TypeError.missingEntity(entry.entityKey) }
            guard data.count == entry.byteCount else { throw SyncV2TypeError.byteCountMismatch }
            guard ObjectID(data: data) == entry.objectId else { throw SyncV2TypeError.digestMismatch }
            if entry.contentType == .entityJSON {
                try CanonicalJSON.validate(data)
            }
        }
    }
}
