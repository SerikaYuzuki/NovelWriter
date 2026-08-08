import AppKit
import SwiftUI

struct AIProofreadingDiffView: View {
    let source: String
    let replacement: String

    var body: some View {
        let difference = AIProofreadingDiff(source: source, replacement: replacement)
        GroupBox("原文との差分") {
            VStack(alignment: .leading, spacing: 16) {
                if difference.hasChanges {
                    if difference.detail == .condensed {
                        Label(
                            "長い範囲のため、共通する前後を残して変更区間をまとめて表示しています。",
                            systemImage: "text.alignleft"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    diffBlock(
                        title: "− 原文（削除箇所）",
                        segments: difference.originalSegments,
                        fullText: source,
                        changedText: difference.removedText,
                        changedKind: .removed
                    )
                    diffBlock(
                        title: "+ 提案（追加箇所）",
                        segments: difference.proposalSegments,
                        fullText: replacement,
                        changedText: difference.insertedText,
                        changedKind: .inserted
                    )
                } else {
                    Label("原文からの変更はありません", systemImage: "equal.circle")
                    AIProofreadingExactDiffText(
                        segments: difference.originalSegments,
                        changedKind: .removed
                    )
                    .accessibilityLabel("原文と提案")
                    .accessibilityValue(source)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffBlock(
        title: String,
        segments: [AIProofreadingDiffSegment],
        fullText: String,
        changedText: String,
        changedKind: AIProofreadingDiffSegmentKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AIProofreadingExactDiffText(
                segments: segments,
                changedKind: changedKind
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("変更箇所: \(changedText)。全文: \(fullText)")
        }
    }
}

private struct AIProofreadingExactDiffText: View {
    let segments: [AIProofreadingDiffSegment]
    let changedKind: AIProofreadingDiffSegmentKind

    var body: some View {
        segments.reduce(Text("")) { result, segment in
            result + styledText(segment)
        }
    }

    private func styledText(_ segment: AIProofreadingDiffSegment) -> Text {
        let text = Text(verbatim: segment.text)
        guard segment.kind == changedKind else { return text }
        switch segment.kind {
        case .removed:
            return text
                .foregroundColor(Color(nsColor: .systemRed))
                .strikethrough()
        case .inserted:
            return text
                .foregroundColor(Color(nsColor: .systemGreen))
                .underline()
        case .unchanged:
            return text
        }
    }
}
