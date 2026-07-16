import Foundation
import NovelCore

/// 形式別レンダラへ渡す、保存形式に依存しない原稿の意味ブロック列。
///
/// `NovelDocument` の章／話走査、空タイトルの表示名、本文改行の正規化を
/// ここで一度だけ確定し、形式別レンダラがモデルを個別走査することを防ぐ。
struct Manuscript: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case documentHeading(String)
        case chapterHeading(String)
        case episodeHeading(String)
        case body(String)
    }

    let blocks: [Block]

    static func expand(_ document: NovelDocument) -> Manuscript {
        var blocks: [Block] = [
            .documentHeading(displayName(document.title, fallback: "無題の作品"))
        ]

        for chapter in document.chapters {
            blocks.append(.chapterHeading(displayName(chapter.title, fallback: "無題の章")))

            for episode in chapter.episodes {
                blocks.append(.episodeHeading(displayName(episode.title, fallback: "本文")))

                let body = normalizedBody(episode.content)
                if !body.isEmpty {
                    blocks.append(.body(body))
                }
            }
        }

        return Manuscript(blocks: blocks)
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
