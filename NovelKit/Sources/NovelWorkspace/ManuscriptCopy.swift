import Foundation

/// コピー文字列へ含められるscope。clipboard通知には原稿のscopeを露出しない。
public enum ManuscriptCopyScope: String, Sendable, Equatable {
    case selection
    case episode
    case chapter
}

/// 章コピー文字列へ含める話データ。
///
/// `Episode`そのものを受け取らず、IDやメモをコピー文字列へ混入できない形に限定する。
public struct ManuscriptCopyEpisode: Sendable, Equatable {
    public let title: String
    public let content: String

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
}

/// 利用者が明示的に選んだ、コピー文字列へ含めてよい原稿データ。
public enum ManuscriptCopySource: Sendable, Equatable {
    case selection(text: String)
    case episode(title: String, content: String)
    case chapter(title: String, episodes: [ManuscriptCopyEpisode])

    public var scope: ManuscriptCopyScope {
        switch self {
        case .selection:
            .selection
        case .episode:
            .episode
        case .chapter:
            .chapter
        }
    }

    fileprivate var includedStrings: [String] {
        switch self {
        case let .selection(text):
            [text]
        case let .episode(title, content):
            [title, content]
        case let .chapter(title, episodes):
            [title] + episodes.flatMap { [$0.title, $0.content] }
        }
    }

    fileprivate var manuscriptContents: [String] {
        switch self {
        case let .selection(text):
            [text]
        case let .episode(_, content):
            [content]
        case let .chapter(_, episodes):
            episodes.map(\.content)
        }
    }
}

/// コピー文字列生成時のローカルresource上限。
///
/// 上限超過時は切り詰めず拒否する。
public struct ManuscriptCopyLimits: Sendable, Equatable {
    public static let standard = ManuscriptCopyLimits(
        maximumSourceCharacters: 250_000,
        maximumSourceUTF8Bytes: 1_000_000,
        maximumOutputUTF8Bytes: 2_000_000
    )

    public let maximumSourceCharacters: Int
    public let maximumSourceUTF8Bytes: Int
    public let maximumOutputUTF8Bytes: Int

    public init(maximumSourceCharacters: Int, maximumSourceUTF8Bytes: Int, maximumOutputUTF8Bytes: Int) {
        self.maximumSourceCharacters = maximumSourceCharacters
        self.maximumSourceUTF8Bytes = maximumSourceUTF8Bytes
        self.maximumOutputUTF8Bytes = maximumOutputUTF8Bytes
    }
}

/// 生成済みコピー文字列と、resource境界を検証するための計数値。
public struct ManuscriptCopy: Sendable, Equatable {
    public let scope: ManuscriptCopyScope
    public let text: String
    public let sourceCharacterCount: Int
    public let sourceUTF8ByteCount: Int
}

public enum ManuscriptCopyError: Error, Sendable, Equatable {
    case emptyContent
    case sourceCharacterLimitExceeded(limit: Int, actual: Int)
    case sourceUTF8ByteLimitExceeded(limit: Int, actual: Int)
    case outputUTF8ByteLimitExceeded(limit: Int, actual: Int)
}

public enum ManuscriptCopyBuilder {
    public static func make(
        source: ManuscriptCopySource,
        limits: ManuscriptCopyLimits = .standard
    ) throws -> ManuscriptCopy {
        guard source.manuscriptContents.contains(where: {
            $0.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
        }) else { throw ManuscriptCopyError.emptyContent }
        let characters = source.includedStrings.reduce(0) { $0 + $1.count }
        let bytes = source.includedStrings.reduce(0) { $0 + $1.utf8.count }
        guard characters <= limits.maximumSourceCharacters else {
            throw ManuscriptCopyError.sourceCharacterLimitExceeded(limit: limits.maximumSourceCharacters, actual: characters)
        }
        guard bytes <= limits.maximumSourceUTF8Bytes else {
            throw ManuscriptCopyError.sourceUTF8ByteLimitExceeded(limit: limits.maximumSourceUTF8Bytes, actual: bytes)
        }
        let text: String
        switch source {
        case let .selection(value):
            text = value
        case let .episode(title, content):
            text = titledBody(title: title, content: content)
        case let .chapter(title, episodes):
            let body = episodes.map { titledBody(title: $0.title, content: $0.content) }.joined(separator: "\n\n")
            text = titledBody(title: title, content: body)
        }
        guard text.utf8.count <= limits.maximumOutputUTF8Bytes else {
            throw ManuscriptCopyError.outputUTF8ByteLimitExceeded(limit: limits.maximumOutputUTF8Bytes, actual: text.utf8.count)
        }
        return ManuscriptCopy(scope: source.scope, text: text, sourceCharacterCount: characters, sourceUTF8ByteCount: bytes)
    }

    private static func titledBody(title: String, content: String) -> String {
        title.isEmpty ? content : title + "\n\n" + content
    }
}
