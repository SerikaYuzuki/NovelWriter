import SwiftUI

/// 編集面を塞がず、書き出しの進捗と結果を伝える一時ステータス。
struct ExportStatusView: View {
    @Bindable var presenter: ExportPresenter

    var body: some View {
        HStack(spacing: 8) {
            statusContent

            if presenter.state.canDismiss {
                Button {
                    presenter.dismissStatus()
                } label: {
                    Label("書き出し状態を閉じる", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("閉じる")
                .accessibilityLabel("書き出し状態を閉じる")
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusContent: some View {
        HStack(spacing: 8) {
            if presenter.state.isExporting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: presenter.state.systemImage)
            }

            Text(presenter.state.message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presenter.state.message)
    }
}
