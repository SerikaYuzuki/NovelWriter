import Foundation

/// 章の中の本文単位(話)を一意に識別するID。
///
/// `EpisodeID` は `ChapterID` と同じ UUID ラッパーだが、型を分けることで
/// 章と話を取り違えた参照をコンパイル時に検出する。
public struct EpisodeID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

extension EpisodeID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// 小説の1話を表すモデル。本文の所有権と編集単位は話に置く(D-028)。
public struct Episode: Codable, Sendable, Identifiable, Equatable {
    /// 旧 Chapter の本文を移行するときに使う既定タイトル。
    public static let defaultTitle = "本文"

    public var id: EpisodeID
    public var title: String
    public var content: String
    public var memo: String

    public init(
        id: EpisodeID = EpisodeID(),
        title: String = Episode.defaultTitle,
        content: String = "",
        memo: String = ""
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.memo = memo
    }
}
