import Foundation

/// 登場人物を一意に識別するID。
public struct CharacterID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

extension CharacterID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// プロットカードを一意に識別するID。
public struct PlotCardID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

extension PlotCardID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// 伏線・フラグを一意に識別するID。
public struct FlagID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

extension FlagID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// 小説に登場する人物設定。配列順が表示順であり、`order` フィールドは持たない。
public struct Character: Codable, Sendable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kana, memo, colorHex, role, age, gender
        case firstPerson, secondPerson, speechStyle, appearance, personality, background
    }

    public var id: CharacterID
    public var name: String
    public var kana: String
    public var memo: String
    public var colorHex: String?
    public var role: String?
    public var age: String?
    public var gender: String?
    public var firstPerson: String?
    public var secondPerson: String?
    public var speechStyle: String?
    public var appearance: String?
    public var personality: String?
    public var background: String?

    public init(
        id: CharacterID = CharacterID(),
        name: String,
        kana: String = "",
        memo: String = "",
        colorHex: String? = nil,
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        self.id = id
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CharacterID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kana = try container.decodeIfPresent(String.self, forKey: .kana) ?? ""
        memo = try container.decodeIfPresent(String.self, forKey: .memo) ?? ""
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        age = try container.decodeIfPresent(String.self, forKey: .age)
        gender = try container.decodeIfPresent(String.self, forKey: .gender)
        firstPerson = try container.decodeIfPresent(String.self, forKey: .firstPerson)
        secondPerson = try container.decodeIfPresent(String.self, forKey: .secondPerson)
        speechStyle = try container.decodeIfPresent(String.self, forKey: .speechStyle)
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance)
        personality = try container.decodeIfPresent(String.self, forKey: .personality)
        background = try container.decodeIfPresent(String.self, forKey: .background)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kana, forKey: .kana)
        try container.encode(memo, forKey: .memo)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(age, forKey: .age)
        try container.encodeIfPresent(gender, forKey: .gender)
        try container.encodeIfPresent(firstPerson, forKey: .firstPerson)
        try container.encodeIfPresent(secondPerson, forKey: .secondPerson)
        try container.encodeIfPresent(speechStyle, forKey: .speechStyle)
        try container.encodeIfPresent(appearance, forKey: .appearance)
        try container.encodeIfPresent(personality, forKey: .personality)
        try container.encodeIfPresent(background, forKey: .background)
    }
}

/// 構成メモやシーンを表すプロットカード。配列順が表示順である。
public struct PlotCard: Codable, Sendable, Identifiable, Equatable {
    public var id: PlotCardID
    public var title: String
    public var memo: String
    public var chapterID: ChapterID?

    public init(id: PlotCardID = PlotCardID(), title: String, memo: String = "", chapterID: ChapterID? = nil) {
        self.id = id
        self.title = title
        self.memo = memo
        self.chapterID = chapterID
    }
}

/// 伏線・未回収フラグを表すモデル。配列順が表示順である。
public struct Flag: Codable, Sendable, Identifiable, Equatable {
    public var id: FlagID
    public var title: String
    public var note: String
    public var isResolved: Bool
    public var plantedChapterID: ChapterID?
    public var resolvedChapterID: ChapterID?

    public init(
        id: FlagID = FlagID(),
        title: String,
        note: String = "",
        isResolved: Bool = false,
        plantedChapterID: ChapterID? = nil,
        resolvedChapterID: ChapterID? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.isResolved = isResolved
        self.plantedChapterID = plantedChapterID
        self.resolvedChapterID = resolvedChapterID
    }
}
