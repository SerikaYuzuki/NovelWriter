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
    /// 章の識別子。
    public var id: ChapterID
    /// 章タイトル。
    public var title: String
    /// 章本文(プレーンテキスト、Markdown互換)。
    public var content: String

    /// 章を作成する。
    /// - Parameters:
    ///   - id: 章の識別子。省略時は新規に生成する。
    ///   - title: 章タイトル。
    ///   - content: 章本文。省略時は空文字列。
    public init(id: ChapterID = ChapterID(), title: String, content: String = "") {
        self.id = id
        self.title = title
        self.content = content
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
