import Foundation

/// 登場人物を一意に識別するID。
public struct CharacterID: Hashable, Codable, Sendable {
    /// 識別に使う実体のUUID。
    public let rawValue: UUID

    /// 既存のUUIDから `CharacterID` を作る。
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// 新規の登場人物のために、ランダムなUUIDで `CharacterID` を生成する。
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
    /// 識別に使う実体のUUID。
    public let rawValue: UUID

    /// 既存のUUIDから `PlotCardID` を作る。
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// 新規のプロットカードのために、ランダムなUUIDで `PlotCardID` を生成する。
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
    /// 識別に使う実体のUUID。
    public let rawValue: UUID

    /// 既存のUUIDから `FlagID` を作る。
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// 新規の伏線のために、ランダムなUUIDで `FlagID` を生成する。
    public init() {
        rawValue = UUID()
    }
}

extension FlagID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// 小説に登場する人物設定。
///
/// 配列順が表示順であり、`order` フィールドは持たない。
public struct Character: Codable, Sendable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kana
        case memo
        case colorHex
        case role
        case age
        case gender
        case firstPerson
        case secondPerson
        case speechStyle
        case appearance
        case personality
        case background
    }

    /// 登場人物の識別子。
    public var id: CharacterID
    /// 表示名。空白だけの名前は ``NovelDocument/normalizedCharacterName(_:)`` で正規化する。
    public var name: String
    /// ふりがな。
    public var kana: String
    /// 自由メモ。
    public var memo: String
    /// 識別用カラー。`#RRGGBB` 形式を想定するが、この層では表示解釈しない。
    public var colorHex: String?
    /// 役割。例: 主人公、ヒロイン、ライバル。
    public var role: String?
    /// 年齢。数値に限定せず「高校二年」「不詳」なども許す。
    public var age: String?
    /// 性別。
    public var gender: String?
    /// 一人称。
    public var firstPerson: String?
    /// 二人称。
    public var secondPerson: String?
    /// 口調・話し方。
    public var speechStyle: String?
    /// 外見。
    public var appearance: String?
    /// 性格。
    public var personality: String?
    /// 背景・経歴。
    public var background: String?

    /// 登場人物を作成する。
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

/// 構成メモやシーンを表すプロットカード。
///
/// 配列順が表示順であり、`order` フィールドは持たない。
public struct PlotCard: Codable, Sendable, Identifiable, Equatable {
    /// プロットカードの識別子。
    public var id: PlotCardID
    /// カードタイトル。
    public var title: String
    /// 自由メモ。
    public var memo: String
    /// 紐付く章。未定の場合は `nil`。
    public var chapterID: ChapterID?

    /// プロットカードを作成する。
    public init(id: PlotCardID = PlotCardID(), title: String, memo: String = "", chapterID: ChapterID? = nil) {
        self.id = id
        self.title = title
        self.memo = memo
        self.chapterID = chapterID
    }
}

/// 伏線・未回収フラグを表すモデル。
///
/// 配列順が表示順であり、`order` フィールドは持たない。
public struct Flag: Codable, Sendable, Identifiable, Equatable {
    /// 伏線の識別子。
    public var id: FlagID
    /// 伏線タイトル。
    public var title: String
    /// 自由メモ。
    public var note: String
    /// 回収済みかどうか。
    public var isResolved: Bool
    /// 伏線を張った章。
    public var plantedChapterID: ChapterID?
    /// 伏線を回収した章。
    public var resolvedChapterID: ChapterID?

    /// 伏線を作成する。
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

public extension NovelDocument {
    /// 空白だけの登場人物名を、保存・表示に耐える名前へ正規化する。
    static func normalizedCharacterName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "名無し" : trimmed
    }

    /// 末尾に登場人物を追加する。
    @discardableResult
    mutating func addCharacter(
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
    ) -> CharacterID {
        let character = Character(
            name: Self.normalizedCharacterName(name),
            kana: kana,
            memo: memo,
            colorHex: colorHex,
            role: role,
            age: age,
            gender: gender,
            firstPerson: firstPerson,
            secondPerson: secondPerson,
            speechStyle: speechStyle,
            appearance: appearance,
            personality: personality,
            background: background
        )
        characters.append(character)
        return character.id
    }

    /// 指定した登場人物を削除する。
    @discardableResult
    mutating func removeCharacter(id: CharacterID) -> Character? {
        guard let index = characters.firstIndex(where: { $0.id == id }) else { return nil }
        return characters.remove(at: index)
    }

    /// 登場人物を並べ替える。
    mutating func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { characters[$0] }
        for index in fromOffsets.sorted(by: >) {
            characters.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        characters.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定した登場人物を更新する。
    mutating func updateCharacter(
        id: CharacterID,
        name: String,
        kana: String,
        memo: String,
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
        guard let index = characters.firstIndex(where: { $0.id == id }) else { return }
        characters[index].name = name
        characters[index].kana = kana
        characters[index].memo = memo
        characters[index].colorHex = colorHex
        characters[index].role = role
        characters[index].age = age
        characters[index].gender = gender
        characters[index].firstPerson = firstPerson
        characters[index].secondPerson = secondPerson
        characters[index].speechStyle = speechStyle
        characters[index].appearance = appearance
        characters[index].personality = personality
        characters[index].background = background
    }

    /// 空白だけのプロットカードタイトルを、保存・表示に耐える名前へ正規化する。
    static func normalizedPlotCardTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のカード" : trimmed
    }

    /// 末尾にプロットカードを追加する。
    @discardableResult
    mutating func addPlotCard(title: String, memo: String = "", chapterID: ChapterID? = nil) -> PlotCardID {
        let card = PlotCard(title: Self.normalizedPlotCardTitle(title), memo: memo, chapterID: chapterID)
        plotCards.append(card)
        return card.id
    }

    /// 指定したプロットカードを削除する。
    @discardableResult
    mutating func removePlotCard(id: PlotCardID) -> PlotCard? {
        guard let index = plotCards.firstIndex(where: { $0.id == id }) else { return nil }
        return plotCards.remove(at: index)
    }

    /// プロットカードを並べ替える。
    mutating func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { plotCards[$0] }
        for index in fromOffsets.sorted(by: >) {
            plotCards.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        plotCards.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定したプロットカードを更新する。
    mutating func updatePlotCard(id: PlotCardID, title: String, memo: String, chapterID: ChapterID?) {
        guard let index = plotCards.firstIndex(where: { $0.id == id }) else { return }
        plotCards[index].title = title
        plotCards[index].memo = memo
        plotCards[index].chapterID = chapterID
    }

    /// 1本の配列順を保ったまま、カードを章レーンへ移動する。
    ///
    /// `plotCards` の配列順だけを正とし、レーン内の順序は
    /// 「同じ `chapterID` を持つカードだけを配列順に射影したもの」として扱う。
    mutating func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        guard let originalIndex = plotCards.firstIndex(where: { $0.id == id }) else { return }

        if targetID == id {
            plotCards[originalIndex].chapterID = chapterID
            return
        }

        var moved = plotCards.remove(at: originalIndex)
        moved.chapterID = chapterID

        let targetIndex = targetID.flatMap { targetID in
            plotCards.firstIndex { $0.id == targetID }
        }
        let insertionIndex: Int = if let targetIndex {
            targetIndex
        } else if let lastInLane = plotCards.lastIndex(where: { $0.chapterID == chapterID }) {
            plotCards.index(after: lastInLane)
        } else {
            plotCards.count
        }

        plotCards.insert(moved, at: insertionIndex)
    }

    /// 指定章に紐付くプロットカードの参照を外す。
    mutating func detachPlotCards(from chapterID: ChapterID) {
        for index in plotCards.indices where plotCards[index].chapterID == chapterID {
            plotCards[index].chapterID = nil
        }
    }

    /// 空白だけの伏線タイトルを、保存・表示に耐える名前へ正規化する。
    static func normalizedFlagTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の伏線" : trimmed
    }

    /// 末尾に伏線を追加する。
    @discardableResult
    mutating func addFlag(
        title: String,
        note: String = "",
        isResolved: Bool = false,
        plantedChapterID: ChapterID? = nil,
        resolvedChapterID: ChapterID? = nil
    ) -> FlagID {
        let flag = Flag(
            title: Self.normalizedFlagTitle(title),
            note: note,
            isResolved: isResolved,
            plantedChapterID: plantedChapterID,
            resolvedChapterID: resolvedChapterID
        )
        flags.append(flag)
        return flag.id
    }

    /// 指定した伏線を削除する。
    @discardableResult
    mutating func removeFlag(id: FlagID) -> Flag? {
        guard let index = flags.firstIndex(where: { $0.id == id }) else { return nil }
        return flags.remove(at: index)
    }

    /// 伏線を並べ替える。
    mutating func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { flags[$0] }
        for index in fromOffsets.sorted(by: >) {
            flags.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        flags.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定した伏線を更新する。
    mutating func updateFlag(_ flag: Flag) {
        guard let index = flags.firstIndex(where: { $0.id == flag.id }) else { return }
        flags[index] = flag
    }

    /// 指定章に紐付く伏線参照を外す。
    mutating func detachFlags(from chapterID: ChapterID) {
        for index in flags.indices {
            if flags[index].plantedChapterID == chapterID {
                flags[index].plantedChapterID = nil
            }
            if flags[index].resolvedChapterID == chapterID {
                flags[index].resolvedChapterID = nil
            }
        }
    }
}
