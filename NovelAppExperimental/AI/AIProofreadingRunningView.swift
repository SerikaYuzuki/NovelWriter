import SwiftUI

@MainActor
struct AIProofreadingRunningView: View {
    let operation: AIProofreadingOperation

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progressHeader
                    unverifiedContent
                }
                .padding(16)
            }

            Divider()
            footer
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.phase == .cancelling ? "キャンセルしています" : "校正案を受信しています")
                    .font(.headline)
                Text("送信中も本文を編集できます。変更された場合、結果は適用不可になります。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unverifiedContent: some View {
        GroupBox("受信中の未検証内容") {
            VStack(alignment: .leading, spacing: 8) {
                Label("完了前の断片は校正結果ではありません", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                if operation.progress.unverifiedReplacement.isEmpty {
                    Text("まだ表示できる断片はありません。")
                        .foregroundStyle(.secondary)
                } else {
                    AIProofreadingExactTextBlock(
                        text: operation.progress.unverifiedReplacement,
                        label: "未検証の受信内容",
                        isMonospaced: false,
                        allowsTextSelection: false
                    )
                }
                Text("厳密なresponse schemaと上限の検証が完了するまで、コピーも本文への適用もできません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Text("Providerを自動で切り替えたり、自動再送したりしません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(operation.phase == .cancelling ? "キャンセル中" : "キャンセル") {
                operation.cancel()
            }
            .buttonStyle(.bordered)
            .disabled(operation.phase == .cancelling)
        }
        .padding(16)
    }
}
