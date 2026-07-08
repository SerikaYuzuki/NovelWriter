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

/// 小説に登場する人物設定。
///
/// 配列順が表示順であり、`order` フィールドは持たない。
public struct Character: Codable, Sendable, Identifiable, Equatable {
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

    /// 登場人物を作成する。
    public init(
        id: CharacterID = CharacterID(),
        name: String,
        kana: String = "",
        memo: String = "",
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kana = kana
        self.memo = memo
        self.colorHex = colorHex
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
        colorHex: String? = nil
    ) -> CharacterID {
        let character = Character(
            name: Self.normalizedCharacterName(name),
            kana: kana,
            memo: memo,
            colorHex: colorHex
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
        colorHex: String? = nil
    ) {
        guard let index = characters.firstIndex(where: { $0.id == id }) else { return }
        characters[index].name = name
        characters[index].kana = kana
        characters[index].memo = memo
        characters[index].colorHex = colorHex
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

    /// 指定章に紐付くプロットカードの参照を外す。
    mutating func detachPlotCards(from chapterID: ChapterID) {
        for index in plotCards.indices where plotCards[index].chapterID == chapterID {
            plotCards[index].chapterID = nil
        }
    }
}
