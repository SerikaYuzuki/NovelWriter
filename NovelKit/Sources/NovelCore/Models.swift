import Foundation

/// 章を一意に識別するID。
///
/// `Chapter` の同一性のためだけに使う軽量な値型。実体は `UUID` のラップであり、
/// `.novelpkg` への保存時にはこの `rawValue` の文字列表現がそのまま
/// 章ファイル名(`chapters/<UUID>.md`)になる(docs/DESIGN.md 4.2, D-003)。
public struct ChapterID: Hashable, Codable, Sendable {
    /// 識別に使う実体のUUID。
    public let rawValue: UUID

    /// 既存のUUIDから `ChapterID` を作る。
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// 新規の章のために、ランダムなUUIDで `ChapterID` を生成する。
    public init() {
        rawValue = UUID()
    }
}

extension ChapterID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// 小説の1章を表すモデル。
///
/// - 重要: 章の並び順を表す `order` フィールドは意図的に持たない。
///   章順は `NovelDocument.chapters` の配列順のみが唯一の正であり、
///   二重管理によるズレを防ぐ(docs/DESIGN.md 4.1, D-004)。
public struct Chapter: Codable, Sendable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case memo
    }

    /// 章の識別子。
    public var id: ChapterID
    /// 章タイトル。
    public var title: String
    /// 章本文(プレーンテキスト、Markdown互換)。
    public var content: String
    /// 章メモ。本文とは別に、短い執筆メモやTODOを保持する。
    public var memo: String

    /// 章を作成する。
    /// - Parameters:
    ///   - id: 章の識別子。省略時は新規に生成する。
    ///   - title: 章タイトル。
    ///   - content: 章本文。省略時は空文字列。
    ///   - memo: 章メモ。省略時は空文字列。
    public init(id: ChapterID = ChapterID(), title: String, content: String = "", memo: String = "") {
        self.id = id
        self.title = title
        self.content = content
        self.memo = memo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ChapterID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        memo = try container.decodeIfPresent(String.self, forKey: .memo) ?? ""
    }
}

/// 1つの小説作品全体を表すモデル。
///
/// 章の並び順は `chapters` 配列の順序そのものが唯一の正であり、
/// 個々の `Chapter` に順序情報を持たせてはならない(D-004)。
public struct NovelDocument: Codable, Sendable, Identifiable, Equatable {
    /// 作品の識別子。
    public var id: UUID
    /// 作品タイトル。
    public var title: String
    /// 章の並び順つきリスト。この配列の順序が章順そのもの。
    public var chapters: [Chapter]

    /// 作品を作成する。
    /// - Parameters:
    ///   - id: 作品の識別子。省略時は新規に生成する。
    ///   - title: 作品タイトル。
    ///   - chapters: 章の並び順つきリスト。
    public init(id: UUID = UUID(), title: String, chapters: [Chapter]) {
        self.id = id
        self.title = title
        self.chapters = chapters
    }

    /// 新規作品を、空の章1つを添えて生成する便利ファクトリ。
    ///
    /// App層が「新規作品を作る」際に、章が1つも無い空のドキュメントではなく、
    /// すぐ編集を始められる状態を用意できるようにするためのもの。
    /// - Parameters:
    ///   - title: 作品タイトル。
    ///   - firstChapterTitle: 最初に用意する章のタイトル。
    public static func newDocument(
        title: String = "新規作品",
        firstChapterTitle: String = "第1章"
    ) -> NovelDocument {
        NovelDocument(
            id: UUID(),
            title: title,
            chapters: [Chapter(title: firstChapterTitle)]
        )
    }

    /// 末尾に新しい章を追加する。
    ///
    /// 章操作のロジックを App 層(`AppState`)ではなくここに置くことで、
    /// App 層を薄く保つ(docs/DESIGN.md 5.2)。
    /// - Parameter title: 新しい章のタイトル。
    /// - Returns: 生成した章の ``ChapterID``。
    @discardableResult
    public mutating func addChapter(title: String) -> ChapterID {
        let chapter = Chapter(title: title)
        chapters.append(chapter)
        return chapter.id
    }

    /// 指定した章のタイトルを更新する。
    ///
    /// 該当する ``ChapterID`` の章が存在しない場合は何もしない。
    /// - Parameters:
    ///   - title: 新しい章タイトル。
    ///   - id: 更新対象の章の ``ChapterID``。
    public mutating func updateTitle(_ title: String, for id: ChapterID) {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        chapters[index].title = title
    }

    /// 指定した章を削除する。
    ///
    /// 章が見つかった場合は削除した章と、削除位置を返す。見つからなければ `nil`。
    /// 章が0件になること自体はモデルとして許容し、アプリ側が必要に応じて
    /// 「最後の1章は削除不可」などの運用ルールを決める。
    /// - Parameter id: 削除対象の章ID。
    /// - Returns: 削除した章と元のインデックス。
    @discardableResult
    public mutating func removeChapter(id: ChapterID) -> (chapter: Chapter, index: Int)? {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = chapters.remove(at: index)
        return (removed, index)
    }

    /// 章を並べ替える。
    ///
    /// `SwiftUI` の `List.onMove(perform:)` がそのまま渡してくる
    /// `(IndexSet, Int)` の形と互換にしてあるため、App 側はそのまま委譲できる。
    /// `Array.move(fromOffsets:toOffset:)` は SwiftUI の拡張であり、NovelCore は
    /// SwiftUI に依存してはならない(docs/DESIGN.md 9.1)ため、同等のロジックを
    /// ここに自前で実装する。
    /// - Parameters:
    ///   - fromOffsets: 移動元のインデックス集合。
    ///   - toOffset: 移動先のインデックス。
    public mutating func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { chapters[$0] }
        for index in fromOffsets.sorted(by: >) {
            chapters.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        chapters.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定した章の本文を更新する。
    ///
    /// 該当する ``ChapterID`` の章が存在しない場合は何もしない(呼び出し側が
    /// 章切り替えの過渡状態などで古い ID を渡してもクラッシュしない)。
    /// - Parameters:
    ///   - content: 新しい本文。
    ///   - id: 更新対象の章の ``ChapterID``。
    public mutating func updateContent(_ content: String, for id: ChapterID) {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        chapters[index].content = content
    }

    /// 指定した章のメモを更新する。
    ///
    /// 該当する ``ChapterID`` の章が存在しない場合は何もしない。
    /// - Parameters:
    ///   - memo: 新しい章メモ。
    ///   - id: 更新対象の章の ``ChapterID``。
    public mutating func updateMemo(_ memo: String, for id: ChapterID) {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        chapters[index].memo = memo
    }

    /// 作品全体の本文文字数。
    ///
    /// 定義は ``ManuscriptMetrics/countCharacters(in:)`` と同じく、
    /// 改行を除いた `Character` 数。章メモは含めない。
    public var manuscriptCharacterCount: Int {
        chapters.reduce(0) { $0 + ManuscriptMetrics.countCharacters(in: $1.content) }
    }
}

/// 原稿本文の文字数など、表示用メトリクスの純粋ロジック。
public enum ManuscriptMetrics {
    /// 改行を除いた `Character` 数を返す。
    ///
    /// 空白・全角スペースは文字数に含める。Swift の `Character` 単位で数えるため、
    /// 絵文字や結合文字列もユーザーの見た目に近い1文字として扱う。
    public static func countCharacters(in text: String) -> Int {
        text.reduce(0) { count, character in
            String(character).rangeOfCharacter(from: .newlines) == nil ? count + 1 : count
        }
    }

    /// 400字詰め原稿用紙に換算した枚数。0文字なら0枚。
    public static func manuscriptPages400(for characterCount: Int) -> Int {
        guard characterCount > 0 else { return 0 }
        return (characterCount + 399) / 400
    }
}

/// 作品データの保存・読み込みを抽象化するプロトコル。
///
/// 実装(例: `.novelpkg` 形式を扱う `NovelpkgRepository`)は NovelStorage に置く。
/// App側はこのプロトコルのみに依存し、保存形式の詳細を知らない
/// (docs/DESIGN.md 9.3)。「最近開いた作品」の追跡はこのプロトコルの責務ではなく
/// App層が持つ(D-009)。
public protocol DocumentRepository: Sendable {
    /// 指定した URL から作品を読み込む。
    /// - Parameter url: 読み込み対象のパッケージ(またはファイル)のURL。
    func load(from url: URL) async throws -> NovelDocument

    /// 指定した URL に作品を保存する。
    /// - Parameters:
    ///   - doc: 保存する作品。
    ///   - url: 保存先のパッケージ(またはファイル)のURL。
    func save(_ doc: NovelDocument, to url: URL) async throws
}

/// スナップショット保存に対応するリポジトリ。
///
/// スナップショットの具体的な置き場所や形式は保存層の責務であり、App 側は
/// このプロトコルを通して「現在の作品状態の退避」だけを依頼する。
public protocol SnapshottingDocumentRepository: DocumentRepository {
    /// 現在の作品状態をスナップショットとして保存する。
    /// - Parameters:
    ///   - doc: スナップショットに残す作品。
    ///   - url: 元の作品パッケージURL。
    /// - Returns: 作成したスナップショットの URL。
    @discardableResult
    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL
}
