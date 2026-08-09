import NovelAI
import SwiftUI

@MainActor
struct AIProofreadingPreviewView: View {
    let operation: AIProofreadingOperation

    var body: some View {
        if let preview = operation.preview {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewNotice
                        providerSection(preview)
                        AIProofreadingExactTextSection(
                            title: "選択本文（送信対象）",
                            text: preview.selectedText.value,
                            isMonospaced: false
                        )
                        AIProofreadingExactTextSection(
                            title: "Application prompt（全文）",
                            text: preview.applicationPrompt,
                            isMonospaced: true
                        )
                        AIProofreadingExactTextSection(
                            title: "Response schema（全文）",
                            text: preview.applicationResponseSchema,
                            isMonospaced: true
                        )
                        identifiersSection(preview)
                        countsAndBudgetSection(preview)
                        disclosureSection(preview)
                    }
                    .padding(16)
                }

                Divider()
                footer
            }
        } else {
            AIProofreadingMissingStateView()
        }
    }

    private var previewNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("送信前の確認", systemImage: "checkmark.shield")
                .font(.headline)
            Text("以下の選択本文、prompt、schemaが送信契約です。作品名、章名、話名、ファイルパスは送信しません。")
                .foregroundStyle(.secondary)
            if operation.providerDisclosure.isDevelopmentFake {
                Label(
                    "現在は開発用Fakeです。外部providerには送信されません。",
                    systemImage: "wrench.and.screwdriver"
                )
                .font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("この操作ごとに送信を確認します。自動再送は行いません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("閉じる") {
                operation.dismiss()
            }
            .buttonStyle(.bordered)
            Button("この内容を送信") {
                operation.confirmAndSend()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("表示中の本文、prompt、schemaを確認した送信先へ一度だけ送ります")
        }
        .padding(16)
    }

    private func providerSection(_ preview: AIOutboundPreview) -> some View {
        GroupBox("送信先") {
            VStack(alignment: .leading, spacing: 8) {
                AIProofreadingPresentationRow("Provider", value: preview.provider.displayName)
                AIProofreadingPresentationRow(
                    "Provider ID",
                    value: preview.provider.id.rawValue,
                    isMonospaced: true
                )
                AIProofreadingPresentationRow("送信先", value: preview.provider.destination)
                AIProofreadingPresentationRow("Model", value: preview.provider.modelDisplayName)
                AIProofreadingPresentationRow(
                    "Model ID",
                    value: preview.provider.modelID,
                    isMonospaced: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func identifiersSection(_ preview: AIOutboundPreview) -> some View {
        GroupBox("契約ID") {
            VStack(alignment: .leading, spacing: 8) {
                AIProofreadingPresentationRow(
                    "Instruction ID",
                    value: preview.applicationInstructionID,
                    isMonospaced: true
                )
                AIProofreadingPresentationRow(
                    "Schema ID",
                    value: preview.applicationResponseSchemaID,
                    isMonospaced: true
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("固定指示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: preview.applicationInstruction)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func countsAndBudgetSection(_ preview: AIOutboundPreview) -> some View {
        GroupBox("文字数・上限") {
            VStack(alignment: .leading, spacing: 8) {
                AIProofreadingPresentationRow(
                    "選択本文",
                    value: "\(preview.selectedTextCharacterCount)文字 / \(preview.selectedTextUTF8ByteCount) bytes",
                    isNumeric: true
                )
                AIProofreadingPresentationRow(
                    "App入力合計",
                    value: "\(preview.inputCharacterCount)文字 / \(preview.inputUTF8ByteCount) bytes",
                    isNumeric: true
                )
                Divider()
                AIProofreadingPresentationRow(
                    "入力上限",
                    value: "\(preview.budget.maximumInputCharacters)文字 / \(preview.budget.maximumInputUTF8Bytes) bytes",
                    isNumeric: true
                )
                AIProofreadingPresentationRow(
                    "出力上限",
                    value: "\(preview.budget.maximumOutputCharacters)文字 / " +
                        "\(preview.budget.maximumOutputUTF8Bytes) bytes",
                    isNumeric: true
                )
                AIProofreadingPresentationRow(
                    "FUMINIWA受入token上限",
                    value: "\(preview.budget.maximumOutputTokens)",
                    isNumeric: true
                )
                AIProofreadingPresentationRow(
                    "注意点件数上限",
                    value: "\(preview.budget.maximumWarnings)件（FUMINIWA受入上限）",
                    isNumeric: true
                )
                AIProofreadingPresentationRow(
                    "制限時間",
                    value: "\(preview.budget.timeoutSeconds)秒",
                    isNumeric: true
                )
                Text(
                    "FUMINIWA受入token上限は、Providerが完了後に報告する使用量を" +
                        "FUMINIWAが検査する上限です。Provider / SDKの生成上限や費用上限は保証しません。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func disclosureSection(_ preview: AIOutboundPreview) -> some View {
        GroupBox("保持・制約") {
            VStack(alignment: .leading, spacing: 8) {
                Text(operation.providerDisclosure.summary)
                AIProofreadingPresentationRow(
                    "セッション保持",
                    value: preview.provider.sessionStorage.presentationText
                )
                AIProofreadingPresentationRow(
                    "学習利用",
                    value: preview.provider.trainingUse.presentationText
                )
                AIProofreadingPresentationRow(
                    "開示版",
                    value: operation.providerDisclosure.revision,
                    isMonospaced: true
                )

                if !operation.providerDisclosure.limitations.isEmpty {
                    Divider()
                    ForEach(operation.providerDisclosure.limitations.indices, id: \.self) { index in
                        Label(
                            operation.providerDisclosure.limitations[index],
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                    }
                }

                Text("FUMINIWAはpreview、結果、差分を作品ファイルや設定へ保存しません。Provider側の保持とは別の範囲です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
