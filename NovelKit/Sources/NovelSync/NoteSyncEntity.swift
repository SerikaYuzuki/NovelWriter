// Canonical entity payloads keep validation next to every encoded field.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable optional_data_string_conversion
import Foundation

public enum NoteSyncEntityKind: String, Codable, Sendable {
    case work
    case chapter
    case episode
    case character
    case plotCard
    case flag
    case worldNote
}

public struct NoteSyncEntityKey: Hashable, Codable, Sendable {
    public let workID: SyncWorkID
    public let kind: NoteSyncEntityKind
    public let entityID: WorkStableID

    public init(workID: SyncWorkID, kind: NoteSyncEntityKind, entityID: WorkStableID) {
        self.workID = workID
        self.kind = kind
        self.entityID = entityID
    }

    public static func work(_ workID: SyncWorkID) -> NoteSyncEntityKey {
        NoteSyncEntityKey(
            workID: workID,
            kind: .work,
            entityID: WorkStableID(rawValue: workID.rawValue)
        )
    }
}

extension NoteSyncEntityKey: Comparable {
    public static func < (lhs: NoteSyncEntityKey, rhs: NoteSyncEntityKey) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.entityID.rawValue.uuidString != rhs.entityID.rawValue.uuidString {
            return lhs.entityID.rawValue.uuidString < rhs.entityID.rawValue.uuidString
        }
        return lhs.workID.rawValue.uuidString < rhs.workID.rawValue.uuidString
    }
}

public struct NoteSyncWorkPayload: Hashable, Codable, Sendable {
    public let documentID: WorkStableID
    public let title: String
    public let synopsis: String
    public let chapterOrder: [WorkStableID]
    public let characterOrder: [WorkStableID]
    public let plotCardOrder: [WorkStableID]
    public let flagOrder: [WorkStableID]
    public let worldNoteOrder: [WorkStableID]

    public init(
        documentID: WorkStableID,
        title: String,
        synopsis: String,
        chapterOrder: [WorkStableID],
        characterOrder: [WorkStableID],
        plotCardOrder: [WorkStableID],
        flagOrder: [WorkStableID],
        worldNoteOrder: [WorkStableID]
    ) {
        self.documentID = documentID
        self.title = title
        self.synopsis = synopsis
        self.chapterOrder = chapterOrder
        self.characterOrder = characterOrder
        self.plotCardOrder = plotCardOrder
        self.flagOrder = flagOrder
        self.worldNoteOrder = worldNoteOrder
    }
}

public struct NoteSyncChapterPayload: Hashable, Codable, Sendable {
    public let title: String
    public let episodeOrder: [WorkStableID]

    public init(title: String, episodeOrder: [WorkStableID]) {
        self.title = title
        self.episodeOrder = episodeOrder
    }
}

public struct NoteSyncEpisodePayload: Hashable, Codable, Sendable {
    public let chapterID: WorkStableID
    public let title: String
    public let content: String
    public let memo: String

    public init(chapterID: WorkStableID, title: String, content: String, memo: String) {
        self.chapterID = chapterID
        self.title = title
        self.content = content
        self.memo = memo
    }
}

public struct NoteSyncCharacterPayload: Hashable, Codable, Sendable {
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

    public init(
        name: String,
        kana: String,
        memo: String,
        colorHex: String?,
        role: String?,
        age: String?,
        gender: String?,
        firstPerson: String?,
        secondPerson: String?,
        speechStyle: String?,
        appearance: String?,
        personality: String?,
        background: String?
    ) {
        self.name = name
        self.kana = kana
        self.memo = memo
        self.colorHex = colorHex
        self.role = role
        self.age = age
        self.gender = gender
        self.firstPerson = firstPerson
        self.secondPerson = secondPerson
        self.speechStyle = speechStyle
        self.appearance = appearance
        self.personality = personality
        self.background = background
    }
}

public struct NoteSyncPlotCardPayload: Hashable, Codable, Sendable {
    public let title: String
    public let memo: String
    public let chapterID: WorkStableID?

    public init(title: String, memo: String, chapterID: WorkStableID?) {
        self.title = title
        self.memo = memo
        self.chapterID = chapterID
    }
}

public struct NoteSyncFlagPayload: Hashable, Codable, Sendable {
    public let title: String
    public let note: String
    public let isResolved: Bool
    public let plantedChapterID: WorkStableID?
    public let resolvedChapterID: WorkStableID?

    public init(
        title: String,
        note: String,
        isResolved: Bool,
        plantedChapterID: WorkStableID?,
        resolvedChapterID: WorkStableID?
    ) {
        self.title = title
        self.note = note
        self.isResolved = isResolved
        self.plantedChapterID = plantedChapterID
        self.resolvedChapterID = resolvedChapterID
    }
}

public struct NoteSyncWorldNotePayload: Hashable, Codable, Sendable {
    public let title: String
    public let content: String

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
}

public enum NoteSyncPayload: Hashable, Sendable {
    case work(NoteSyncWorkPayload)
    case chapter(NoteSyncChapterPayload)
    case episode(NoteSyncEpisodePayload)
    case character(NoteSyncCharacterPayload)
    case plotCard(NoteSyncPlotCardPayload)
    case flag(NoteSyncFlagPayload)
    case worldNote(NoteSyncWorldNotePayload)

    public var kind: NoteSyncEntityKind {
        switch self {
        case .work: .work
        case .chapter: .chapter
        case .episode: .episode
        case .character: .character
        case .plotCard: .plotCard
        case .flag: .flag
        case .worldNote: .worldNote
        }
    }
}

public enum NoteSyncRecordError: Error, Equatable, Sendable {
    case kindMismatch
    case digestMismatch
    case payloadTooLarge
    case nonCanonicalJSON
}

public struct NoteSyncRecord: Hashable, Codable, Sendable {
    public static let maximumPayloadUTF8Bytes = WorkSnapshot.maximumStringUTF8Bytes

    public let protocolVersion: Int
    public let key: NoteSyncEntityKey
    public let payload: NoteSyncPayload
    public let digest: SyncContentDigest

    public init(key: NoteSyncEntityKey, payload: NoteSyncPayload) throws {
        guard key.kind == payload.kind else {
            throw NoteSyncRecordError.kindMismatch
        }
        let canonical = try NoteSyncCanonicalJSON.encodePayload(payload)
        guard canonical.count <= Self.maximumPayloadUTF8Bytes else {
            throw NoteSyncRecordError.payloadTooLarge
        }
        protocolVersion = NoteSyncWireProtocol.currentVersion
        self.key = key
        self.payload = payload
        digest = SyncContentDigest(content: String(decoding: canonical, as: UTF8.self))
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case workID
        case kind
        case entityID
        case payload
        case digest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentNoteSyncWireVersion(forKey: .protocolVersion, in: container)
        protocolVersion = NoteSyncWireProtocol.currentVersion
        let workID = try container.decode(SyncWorkID.self, forKey: .workID)
        let kind = try container.decode(NoteSyncEntityKind.self, forKey: .kind)
        let entityID = try container.decode(WorkStableID.self, forKey: .entityID)
        key = NoteSyncEntityKey(workID: workID, kind: kind, entityID: entityID)
        payload = try NoteSyncCanonicalJSON.decodePayload(
            from: container.superDecoder(forKey: .payload),
            kind: kind
        )
        digest = try container.decode(SyncContentDigest.self, forKey: .digest)
        let canonical = try NoteSyncCanonicalJSON.encodePayload(payload)
        let expected = SyncContentDigest(content: String(decoding: canonical, as: UTF8.self))
        guard expected == digest else {
            throw NoteSyncRecordError.digestMismatch
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(key.workID, forKey: .workID)
        try container.encode(key.kind, forKey: .kind)
        try container.encode(key.entityID, forKey: .entityID)
        try payload.encode(to: container.superEncoder(forKey: .payload))
        try container.encode(digest, forKey: .digest)
    }
}

public enum NoteSyncCanonicalJSON {
    public static func encodePayload(_ payload: NoteSyncPayload) throws -> Data {
        try encoder().encode(PayloadBox(payload: payload))
    }

    static func decodePayload(from decoder: Decoder, kind: NoteSyncEntityKind) throws -> NoteSyncPayload {
        switch kind {
        case .work:
            try .work(NoteSyncWorkPayload(from: decoder))
        case .chapter:
            try .chapter(NoteSyncChapterPayload(from: decoder))
        case .episode:
            try .episode(NoteSyncEpisodePayload(from: decoder))
        case .character:
            try .character(NoteSyncCharacterPayload(from: decoder))
        case .plotCard:
            try .plotCard(NoteSyncPlotCardPayload(from: decoder))
        case .flag:
            try .flag(NoteSyncFlagPayload(from: decoder))
        case .worldNote:
            try .worldNote(NoteSyncWorldNotePayload(from: decoder))
        }
    }

    public static func decodePayload(from data: Data, kind: NoteSyncEntityKind) throws -> NoteSyncPayload {
        let decoder = JSONDecoder()
        switch kind {
        case .work:
            return try .work(decoder.decode(NoteSyncWorkPayload.self, from: data))
        case .chapter:
            return try .chapter(decoder.decode(NoteSyncChapterPayload.self, from: data))
        case .episode:
            return try .episode(decoder.decode(NoteSyncEpisodePayload.self, from: data))
        case .character:
            return try .character(decoder.decode(NoteSyncCharacterPayload.self, from: data))
        case .plotCard:
            return try .plotCard(decoder.decode(NoteSyncPlotCardPayload.self, from: data))
        case .flag:
            return try .flag(decoder.decode(NoteSyncFlagPayload.self, from: data))
        case .worldNote:
            return try .worldNote(decoder.decode(NoteSyncWorldNotePayload.self, from: data))
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct PayloadBox: Encodable {
        let payload: NoteSyncPayload

        func encode(to encoder: Encoder) throws {
            try payload.encode(to: encoder)
        }
    }
}

extension NoteSyncPayload {
    func encode(to encoder: Encoder) throws {
        switch self {
        case let .work(value):
            try value.encode(to: encoder)
        case let .chapter(value):
            try value.encode(to: encoder)
        case let .episode(value):
            try value.encode(to: encoder)
        case let .character(value):
            try value.encode(to: encoder)
        case let .plotCard(value):
            try value.encode(to: encoder)
        case let .flag(value):
            try value.encode(to: encoder)
        case let .worldNote(value):
            try value.encode(to: encoder)
        }
    }
}
