import Foundation

struct SnapshotClosureValidator {
    private let entriesByKey: [String: SnapshotEntry]
    private let objects: [ObjectID: Data]
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

    init(manifest: SnapshotManifest, objects: [ObjectID: Data]) {
        entriesByKey = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.entityKey, $0) }
        )
        self.objects = objects
    }

    mutating func validate() throws {
        let referencedObjects = Set(entriesByKey.values.map(\.objectId))
        guard Set(objects.keys) == referencedObjects else {
            throw SyncV2TypeError.referenceViolation("object closure")
        }

        _ = try objectFields("work/document")
        _ = try data("work/title")
        _ = try data("work/synopsis")

        let chapterIDs = try order("work/chapter-order")
        let characterIDs = try order("work/character-order")
        let plotCardIDs = try order("work/plot-card-order")
        let flagIDs = try order("work/flag-order")
        let worldNoteIDs = try order("work/world-note-order")
        let attachmentIDs = try order("work/attachment-order")

        try validateChapters(chapterIDs)
        try validateCharacters(characterIDs)
        try validatePlotCards(plotCardIDs, chapterIDs: Set(chapterIDs))
        try validateFlags(flagIDs, chapterIDs: Set(chapterIDs))
        try validateWorldNotes(worldNoteIDs)
        try validateAttachments(attachmentIDs)

        guard Set(entriesByKey.keys) == expectedEntityKeys else {
            throw SyncV2TypeError.referenceViolation("entity closure")
        }
    }

    private mutating func validateChapters(_ chapterIDs: [String]) throws {
        var ownedEpisodes = Set<String>()
        for chapterID in chapterIDs {
            let prefix = "chapter/\(chapterID)"
            let titleKey = "\(prefix)/title"
            let orderKey = "\(prefix)/episode-order"
            expectedEntityKeys.formUnion([titleKey, orderKey])
            _ = try data(titleKey)
            let episodeIDs = try order(orderKey)
            for episodeID in episodeIDs {
                guard ownedEpisodes.insert(episodeID).inserted else {
                    throw SyncV2TypeError.referenceViolation("episode ownership")
                }
                let episodePrefix = "episode/\(episodeID)"
                for suffix in ["title", "body", "memo"] {
                    let key = "\(episodePrefix)/\(suffix)"
                    expectedEntityKeys.insert(key)
                    _ = try data(key)
                }
            }
        }
    }

    private mutating func validateCharacters(_ identifiers: [String]) throws {
        for identifier in identifiers {
            let key = "character/\(identifier)"
            expectedEntityKeys.insert(key)
            let fields = try objectFields(key)
            guard try uuidValue(fields, "id", key) == identifier else {
                throw SyncV2TypeError.referenceViolation(key)
            }
        }
    }

    private mutating func validatePlotCards(
        _ identifiers: [String],
        chapterIDs: Set<String>
    ) throws {
        for identifier in identifiers {
            let key = "plot-card/\(identifier)"
            expectedEntityKeys.insert(key)
            let fields = try objectFields(key)
            guard try uuidValue(fields, "id", key) == identifier else {
                throw SyncV2TypeError.referenceViolation(key)
            }
            if let chapterID = try optionalUUIDValue(fields, "chapterId", key),
               !chapterIDs.contains(chapterID) {
                throw SyncV2TypeError.referenceViolation(key)
            }
        }
    }

    private mutating func validateFlags(
        _ identifiers: [String],
        chapterIDs: Set<String>
    ) throws {
        for identifier in identifiers {
            let key = "flag/\(identifier)"
            expectedEntityKeys.insert(key)
            let fields = try objectFields(key)
            guard try uuidValue(fields, "id", key) == identifier else {
                throw SyncV2TypeError.referenceViolation(key)
            }
            for field in ["plantedChapterId", "resolvedChapterId"] {
                if let chapterID = try optionalUUIDValue(fields, field, key),
                   !chapterIDs.contains(chapterID) {
                    throw SyncV2TypeError.referenceViolation(key)
                }
            }
        }
    }

    private mutating func validateWorldNotes(_ identifiers: [String]) throws {
        for identifier in identifiers {
            let key = "world-note/\(identifier)"
            expectedEntityKeys.insert(key)
            let fields = try objectFields(key)
            guard try uuidValue(fields, "id", key) == identifier else {
                throw SyncV2TypeError.referenceViolation(key)
            }
        }
    }

    private mutating func validateAttachments(_ identifiers: [String]) throws {
        for identifier in identifiers {
            let metadataKey = "attachment/\(identifier)/metadata"
            let bytesKey = "attachment/\(identifier)/bytes"
            expectedEntityKeys.formUnion([metadataKey, bytesKey])
            let metadata = try objectFields(metadataKey)
            guard try uuidValue(metadata, "attachmentId", metadataKey) == identifier,
                  case let .number(byteCount) = metadata["byteCount"],
                  byteCount >= 0,
                  byteCount <= Int64(SnapshotSyncV2Limits.maxObjectBytes) else {
                throw SyncV2TypeError.referenceViolation(metadataKey)
            }
            let bytes = try data(bytesKey, contentType: .octetStream)
            guard Int64(bytes.count) == byteCount else {
                throw SyncV2TypeError.byteCountMismatch
            }
        }
    }

    private func objectFields(
        _ key: String
    ) throws -> [String: CanonicalJSON.Value] {
        guard let entry = entriesByKey[key],
              entry.contentType == .entityJSON,
              let bytes = objects[entry.objectId],
              case let .object(pairs) = try CanonicalJSON.parseObject(
                  bytes,
                  maxBytes: SnapshotSyncV2Limits.maxStructuredEntityBytes
              ) else {
            throw SyncV2TypeError.missingEntity(key)
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    private func data(
        _ key: String,
        contentType: SnapshotEntry.ContentType = .entityJSON
    ) throws -> Data {
        guard let entry = entriesByKey[key],
              entry.contentType == contentType,
              let bytes = objects[entry.objectId] else {
            throw SyncV2TypeError.schemaViolation(key)
        }
        return bytes
    }

    private func stringValue(
        _ fields: [String: CanonicalJSON.Value],
        _ field: String,
        _ key: String
    ) throws -> String {
        guard case let .string(value) = fields[field] else {
            throw SyncV2TypeError.referenceViolation(key)
        }
        return value
    }

    private func uuidValue(
        _ fields: [String: CanonicalJSON.Value],
        _ field: String,
        _ key: String
    ) throws -> String {
        let value = try stringValue(fields, field, key)
        guard SyncV2UUID.parse(value) != nil else {
            throw SyncV2TypeError.referenceViolation(key)
        }
        return value
    }

    private func optionalUUIDValue(
        _ fields: [String: CanonicalJSON.Value],
        _ field: String,
        _ key: String
    ) throws -> String? {
        guard let value = fields[field] else {
            throw SyncV2TypeError.referenceViolation(key)
        }
        if case .null = value {
            return nil
        }
        return try uuidValue(fields, field, key)
    }

    private func order(_ key: String) throws -> [String] {
        let fields = try objectFields(key)
        guard fields.keys.count == 1,
              let identifiers = fields["ids"],
              case let .array(values) = identifiers,
              values.count <= SnapshotSyncV2Limits.maxEntries else {
            throw SyncV2TypeError.referenceViolation(key)
        }
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            guard case let .string(identifier) = value,
                  SyncV2UUID.parse(identifier) != nil,
                  seen.insert(identifier).inserted else {
                throw SyncV2TypeError.referenceViolation(key)
            }
            result.append(identifier)
        }
        return result
    }
}
