import AppKit
import NovelAI
import SwiftUI

@MainActor
struct AIProofreadingResultView: View {
    private enum CopiedPayload: Equatable {
        case source
        case replacement

        var message: String {
            switch self {
            case .source:
                "原文をコピーしました。"
            case .replacement:
                "提案をコピーしました。"
            }
        }
    }

    let operation: AIProofreadingOperation
    @State private var copiedPayload: CopiedPayload?

    var body: some View {
        if let presentation = operation.resultPresentation {
            VStack(spacing: 0) {
                ScrollView {
                    resultSections(presentation)
                        .padding(16)
                }

                Divider()
                footer(presentation)
            }
        } else {
            AIProofreadingMissingStateView()
        }
    }

    private func resultSections(
        _ presentation: AIProofreadingResultPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let staleReason = presentation.staleReason {
                staleNotice(staleReason)
            } else if operation.phase == .applied {
                Label("校正案を本文へ適用しました。1回のUndoで原文へ戻せます。", systemImage: "checkmark.circle")
                    .font(.headline)
            }

            AIProofreadingDiffView(
                source: presentation.source,
                replacement: presentation.result.replacement
            )
            summarySection(presentation.result.summary)
            warningsSection(presentation.result.warnings)
            usageSection(presentation.result)

            Text("この結果と差分はFUMINIWAの作品ファイルや設定へ保存されません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summarySection(_ summary: String) -> some View {
        GroupBox("要約") {
            Text(verbatim: summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func warningsSection(_ warnings: [String]) -> some View {
        GroupBox("注意点") {
            VStack(alignment: .leading, spacing: 8) {
                if warnings.isEmpty {
                    Text("注意点はありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(warnings.indices, id: \.self) { index in
                        Label(warnings[index], systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func staleNotice(_ reason: AIProofreadingStaleReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("現在の原稿には適用できません", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(reason.presentationMessage)
            Text("結果の閲覧とコピーはできます。現在の選択へ読み替えて適用することはありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func usageSection(_ result: AIResult) -> some View {
        GroupBox("利用量（事後報告）") {
            VStack(alignment: .leading, spacing: 8) {
                AIProofreadingPresentationRow(
                    "入力tokens",
                    value: result.usage.inputTokens.map(String.init) ?? "未報告",
                    isNumeric: result.usage.inputTokens != nil
                )
                AIProofreadingPresentationRow(
                    "出力tokens",
                    value: result.usage.outputTokens.map(String.init) ?? "未報告",
                    isNumeric: result.usage.outputTokens != nil
                )
                AIProofreadingPresentationRow(
                    "結果の文字数",
                    value: "\(result.outputCharacterCount)文字 / \(result.outputUTF8ByteCount) bytes",
                    isNumeric: true
                )
                Text("利用量は費用上限の保証ではありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func footer(_ presentation: AIProofreadingResultPresentation) -> some View {
        HStack(spacing: 8) {
            if let copiedPayload {
                Text(copiedPayload.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("原文をコピー") {
                copy(presentation.source, payload: .source)
            }
            .buttonStyle(.bordered)
            Button("提案をコピー") {
                copy(presentation.result.replacement, payload: .replacement)
            }
            .buttonStyle(.bordered)
            Button(operation.phase == .applied ? "適用済み" : "本文へ適用") {
                operation.applyResult()
            }
            .buttonStyle(.borderedProminent)
            .disabled(operation.phase != .result || !presentation.canApply)
            .accessibilityHint("確認した提案で元の選択範囲だけを置換します")
        }
        .padding(16)
    }

    private func copy(_ text: String, payload: CopiedPayload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copiedPayload = payload
    }
}
