import SwiftUI

@MainActor
struct AIProofreadingFailureView: View {
    let operation: AIProofreadingOperation
    let canCaptureEditorSelection: Bool

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                operation.phase == .invalidated ? "再確認が必要です" : "校正できませんでした",
                systemImage: "exclamationmark.triangle",
                description: Text(operation.failure?.presentationMessage ?? "状態を確認できませんでした。")
            )
            AIProofreadingRecoveryActions(
                operation: operation,
                canCaptureEditorSelection: canCaptureEditorSelection
            )
        }
        .padding(16)
    }
}

@MainActor
struct AIProofreadingCancelledView: View {
    let operation: AIProofreadingOperation
    let canCaptureEditorSelection: Bool

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "校正をキャンセルしました",
                systemImage: "xmark.circle",
                description: Text("原文は変更されていません。再実行には新しい送信確認が必要です。")
            )
            AIProofreadingRecoveryActions(
                operation: operation,
                canCaptureEditorSelection: canCaptureEditorSelection
            )
        }
        .padding(16)
    }
}

@MainActor
private struct AIProofreadingRecoveryActions: View {
    let operation: AIProofreadingOperation
    let canCaptureEditorSelection: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("閉じる") {
                    operation.dismiss()
                }
                .buttonStyle(.bordered)
                Button("選択を取り直す") {
                    operation.preparePreview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCaptureEditorSelection)
            }

            if !canCaptureEditorSelection {
                Text("本文エディタを表示し、校正する範囲を選択してから再実行してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
