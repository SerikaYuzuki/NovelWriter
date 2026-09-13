import SwiftUI

/// A read-only native renderer; source Markdown stays unchanged in storage.
struct AssistantMarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(AssistantMarkdown.blocks(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(level == 1 ? .title : level == 2 ? .title2 : .headline)
                .bold().padding(.top, 8).accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            inline(text).fixedSize(horizontal: false, vertical: true)
        case let .item(marker, text, depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(min(depth, 8)) * 16)
        case let .quote(text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.45)).frame(width: 3)
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty {
                    Text(verbatim: language).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: text).font(.system(.body, design: .monospaced)).fixedSize()
                }
            }.padding(12).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .table(rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).fontWeight(index == 0 ? .semibold : .regular)
                                    .frame(minWidth: 100, maxWidth: 260, alignment: .leading)
                                    .padding(12)
                                    .frame(maxHeight: .infinity, alignment: .topLeading)
                                    .background(.secondary.opacity(index == 0 ? 0.12 : index.isMultiple(of: 2) ? 0.05 : 0))
                                    .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inline(_ text: String) -> Text {
        Text(AssistantMarkdown.inline(text))
    }
}
