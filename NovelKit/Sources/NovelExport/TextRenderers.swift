import Foundation

struct PlainTextRenderer {
    func render(_ manuscript: Manuscript) -> String {
        TextBlockComposer.compose(manuscript) { block in
            switch block {
            case let .documentHeading(title):
                "【\(title)】"
            case let .chapterHeading(title):
                "■ \(title)"
            case let .episodeHeading(title):
                "● \(title)"
            case let .body(content):
                content
            }
        }
    }
}

struct MarkdownRenderer {
    func render(_ manuscript: Manuscript) -> String {
        TextBlockComposer.compose(manuscript) { block in
            switch block {
            case let .documentHeading(title):
                "# \(title)"
            case let .chapterHeading(title):
                "## \(title)"
            case let .episodeHeading(title):
                "### \(title)"
            case let .body(content):
                // ユーザーが入力したMarkdown互換記法は意図的にエスケープしない。
                content
            }
        }
    }
}

private enum TextBlockComposer {
    static func compose(
        _ manuscript: Manuscript,
        renderBlock: (Manuscript.Block) -> String
    ) -> String {
        let renderedBlocks = manuscript.blocks.map(renderBlock)
        return renderedBlocks.joined(separator: "\n\n") + "\n"
    }
}
