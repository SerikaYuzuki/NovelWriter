import SwiftUI

@MainActor
struct AIProofreadingPanelView: View {
    let operation: AIProofreadingOperation
    let canCaptureEditorSelection: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 240, idealHeight: 360, maxHeight: 520)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI校正パネル")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("AI校正（実験）", systemImage: "sparkles")
                .font(.headline)

            if operation.providerDisclosure.isDevelopmentFake {
                Text("開発用Fake")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("開発用Fake provider")
            }

            Text(operation.phase.presentationTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(operation.providerDescriptor.displayName)
                Text(operation.providerDescriptor.modelDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Button {
                operation.dismiss()
            } label: {
                Label("AI校正パネルを閉じる", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("AI校正パネルを閉じる")
            .accessibilityHint(operation.isRequestInFlight ? "実行中の校正をキャンセルします" : "結果を破棄します")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch operation.phase {
        case .idle:
            ContentUnavailableView(
                "校正対象がありません",
                systemImage: "text.badge.checkmark",
                description: Text("本文を選択し、AIメニューから「選択範囲を校正…」を実行してください。")
            )
        case .preview:
            AIProofreadingPreviewView(operation: operation)
        case .running, .cancelling:
            AIProofreadingRunningView(operation: operation)
        case .result, .applied:
            AIProofreadingResultView(operation: operation)
        case .failed, .invalidated:
            AIProofreadingFailureView(
                operation: operation,
                canCaptureEditorSelection: canCaptureEditorSelection
            )
        case .cancelled:
            AIProofreadingCancelledView(
                operation: operation,
                canCaptureEditorSelection: canCaptureEditorSelection
            )
        }
    }
}
