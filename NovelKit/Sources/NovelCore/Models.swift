import Foundation

/// 章を一意に識別するID。
///
/// `Chapter` の同一性のためだけに使う軽量な値型。実体は `UUID` のラップであり、
/// `.novelpkg` の manifest ではこの `rawValue` が章エントリの識別子になる
/// (docs/DESIGN.md 4.2, D-003)。本文ファイル名は `EpisodeID` が担う。
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

/// 小説の1章を表す構造。本文は ``episodes`` に属する(D-028)。
///
/// - 重要: 章の並び順を表す `order` フィールドは意図的に持たない。
///   章順は `NovelDocument.chapters` の配列順のみが唯一の正であり、
///   二重管理によるズレを防ぐ(docs/DESIGN.md 4.1, D-004)。
public struct Chapter: Codable, Sendable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case episodes
        // v1 / v2 の JSON を直接 decode するための互換キー。
        case content
        case memo
    }

    public var id: ChapterID
    public var title: String
    public var episodes: [Episode]

    /// 旧API互換の初期化子。本文とメモは「本文」という話へ格納する。
    public init(id: ChapterID = ChapterID(), title: String, content: String = "", memo: String = "") {
        self.id = id
        self.title = title
        episodes = [
            Episode(
                id: EpisodeID(rawValue: id.rawValue),
                title: Episode.defaultTitle,
                content: content,
                memo: memo
            )
        ]
    }

    /// 話を明示して章を作成する。空の章もこの初期化子で表現できる。
    public init(id: ChapterID = ChapterID(), title: String, episodes: [Episode]) {
        self.id = id
        self.title = title
        self.episodes = episodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ChapterID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        if let decodedEpisodes = try container.decodeIfPresent([Episode].self, forKey: .episodes) {
            episodes = decodedEpisodes
        } else {
            // NovelCore 単体で v1 / v2 の JSON を扱う場合も無損失で話へ移す。
            let content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            let memo = try container.decodeIfPresent(String.self, forKey: .memo) ?? ""
            episodes = [
                Episode(
                    id: EpisodeID(rawValue: id.rawValue),
                    title: Episode.defaultTitle,
                    content: content,
                    memo: memo
                )
            ]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(episodes, forKey: .episodes)
    }
}

/// 1つの小説作品全体を表すモデル。
///
/// 章の並び順は `chapters` 配列の順序そのものが唯一の正であり、
/// 個々の `Chapter` に順序情報を持たせてはならない(D-004)。
public struct NovelDocument: Codable, Sendable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case chapters
        case characters
        case plotCards
        case flags
    }

    /// 作品の識別子。
    public var id: UUID
    /// 作品タイトル。
    public var title: String
    /// 章の並び順つきリスト。この配列の順序が章順そのもの。
    public var chapters: [Chapter]
    /// 登場人物リスト。この配列の順序が表示順そのもの。
    public var characters: [Character]
    /// プロットカードリスト。この配列の順序が表示順そのもの。
    public var plotCards: [PlotCard]
    /// 伏線・フラグリスト。この配列の順序が表示順そのもの。
    public var flags: [Flag]

    /// 作品を作成する。
    /// - Parameters:
    ///   - id: 作品の識別子。省略時は新規に生成する。
    ///   - title: 作品タイトル。
    ///   - chapters: 章の並び順つきリスト。
    ///   - characters: 登場人物リスト。
    public init(
        id: UUID = UUID(),
        title: String,
        chapters: [Chapter],
        characters: [Character] = [],
        plotCards: [PlotCard] = [],
        flags: [Flag] = []
    ) {
        self.id = id
        self.title = title
        self.chapters = chapters
        self.characters = characters
        self.plotCards = plotCards
        self.flags = flags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        chapters = try container.decode([Chapter].self, forKey: .chapters)
        characters = try container.decodeIfPresent([Character].self, forKey: .characters) ?? []
        plotCards = try container.decodeIfPresent([PlotCard].self, forKey: .plotCards) ?? []
        flags = try container.decodeIfPresent([Flag].self, forKey: .flags) ?? []
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
        let chapter = Chapter(title: title, episodes: [])
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
        detachPlotCards(from: id)
        detachFlags(from: id)
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

    /// 作品全体の本文文字数。
    ///
    /// 定義は ``ManuscriptMetrics/countCharacters(in:)`` と同じく、
    /// 改行を除いた `Character` 数。章メモは含めない。
    public var manuscriptCharacterCount: Int {
        chapters.reduce(0) { total, chapter in
            total + chapter.episodes.reduce(0) { episodeTotal, episode in
                episodeTotal + ManuscriptMetrics.countCharacters(in: episode.content)
            }
        }
    }
}

/// 原稿本文の文字数など、表示用メトリクスの純粋ロジック。
public enum ManuscriptMetrics {
    /// 改行を除いた `Character` 数を返す。
    ///
    /// 空白・全角スペースは文字数に含める。Swift の `Character` 単位で数えるため、
    /// 絵文字や結合文字列もユーザーの見た目に近い1文字として扱う。
    ///
    /// キーストロークごとに全章合計で呼ばれる想定のため、`Character` ごとに
    /// `String` を確保して `rangeOfCharacter(from:)` を呼ぶのは避け、
    /// `Character.isNewline` で直接判定する(`\r\n` のような複数スカラーの
    /// 改行も1つの `Character`(拡張書記素クラスタ)として正しく判定される)。
    public static func countCharacters(in text: String) -> Int {
        text.reduce(0) { count, character in
            character.isNewline ? count : count + 1
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

/// 作品パッケージを別 URL へ複製保存できるリポジトリ。
///
/// 本文モデルに含まれない資料・スナップショット・将来追加される保存項目も含めて
/// 「別名で保存」を成立させるための能力を表す。具体的なパッケージ構造は保存層に
/// 閉じ込め、App 層は元 URL と保存先 URL だけを渡す。
public protocol DocumentCopyingRepository: DocumentRepository {
    /// 現在の作品内容と、元の保存先にだけ存在する付随データを別 URL へ保存する。
    /// - Parameters:
    ///   - doc: 保存する現在の作品モデル。
    ///   - sourceURL: 付随データを引き継ぐ元の作品 URL。
    ///   - destinationURL: 複製先 URL。
    func saveCopy(_ doc: NovelDocument, from sourceURL: URL, to destinationURL: URL) async throws
}

/// 作品パッケージ内に保存されたスナップショットの一覧項目。
///
/// 置き場所やファイル名規則は保存層の詳細であり、App 側はこの値の
/// `url` / `displayName` / `createdAt` だけを使う(docs/PHASE5.md 4.5-3a)。
public struct DocumentSnapshotInfo: Identifiable, Hashable, Sendable {
    public var id: URL {
        url
    }

    /// スナップショット本体の URL(読み込み・Finder 表示・復元の入力に使う)。
    public let url: URL
    /// 作成時刻(新しい順の並べ替えと表示に使う)。
    public let createdAt: Date
    /// UI 向けの表示名(保存層がロケールに合わせて組み立てる)。
    public let displayName: String

    public init(url: URL, createdAt: Date, displayName: String) {
        self.url = url
        self.createdAt = createdAt
        self.displayName = displayName
    }
}

/// スナップショット保存・一覧・復元に対応するリポジトリ。
///
/// スナップショットの具体的な置き場所や形式は保存層の責務であり、App 側は
/// このプロトコルを通して退避・一覧・復元だけを依頼する(D-017、PHASE5 4.5-3a)。
public protocol SnapshottingDocumentRepository: DocumentRepository {
    /// 現在の作品状態をスナップショットとして保存する。
    /// - Parameters:
    ///   - doc: スナップショットに残す作品。
    ///   - url: 元の作品パッケージURL。
    /// - Returns: 作成したスナップショットの URL。
    @discardableResult
    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL

    /// 作品パッケージに保存されているスナップショットを新しい順で返す。
    /// - Parameter url: 元の作品パッケージURL。
    func listSnapshots(in url: URL) async throws -> [DocumentSnapshotInfo]

    /// 指定スナップショットの内容を現在の作品パッケージへ書き戻す。
    ///
    /// 既存のスナップショット一覧は保持する。復元前に現在状態を退避するのは
    /// 呼び出し側の責務とする。
    /// - Parameters:
    ///   - snapshotURL: 書き戻すスナップショットの URL。
    ///   - packageURL: 現在の作品パッケージURL。
    func restoreSnapshot(from snapshotURL: URL, into packageURL: URL) async throws
}
