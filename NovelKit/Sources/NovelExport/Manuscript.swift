import Foundation
import NovelCore

/// 形式別レンダラへ渡す、保存形式に依存しない原稿の意味ブロック列。
///
/// `NovelDocument` の章／話走査、空タイトルの表示名、本文改行の正規化を
/// ここで一度だけ確定し、形式別レンダラがモデルを個別走査することを防ぐ。
struct Manuscript: Equatable, Sendable {
    struct Chapter: Equatable, Sendable {
        let title: String
        let episodes: [Episode]
    }

    struct Episode: Equatable, Sendable {
        let title: String
        let body: String?
    }

    enum Block: Equatable, Sendable {
        case documentHeading(String)
        case chapterHeading(String)
        case episodeHeading(String)
        case body(String)
    }

    let identifier: UUID
    let title: String
    let chapters: [Chapter]

    var blocks: [Block] {
        var blocks: [Block] = [.documentHeading(title)]
        for chapter in chapters {
            blocks.append(.chapterHeading(chapter.title))
            for episode in chapter.episodes {
                blocks.append(.episodeHeading(episode.title))
                if let body = episode.body {
                    blocks.append(.body(body))
                }
            }
        }
        return blocks
    }

    static func expand(_ document: NovelDocument) -> Manuscript {
        let chapters = document.chapters.map { chapter in
            let episodes = chapter.episodes.map { episode in
                let body = normalizedBody(episode.content)
                return Episode(
                    title: displayName(episode.title, fallback: "本文"),
                    body: body.isEmpty ? nil : body
                )
            }
            return Chapter(
                title: displayName(chapter.title, fallback: "無題の章"),
                episodes: episodes
            )
        }

        return Manuscript(
            identifier: document.id,
            title: displayName(document.title, fallback: "無題の作品"),
            chapters: chapters
        )
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedBody(_ value: String) -> String {
        var normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // ブロック間の空行とファイル末尾をレンダラ側で一意に決めるため、
        // 本文ブロック末尾のLFだけを除く。先頭空白・内部空行・中間改行は保持する。
        while normalized.last == "\n" {
            normalized.removeLast()
        }
        return normalized
    }
}
