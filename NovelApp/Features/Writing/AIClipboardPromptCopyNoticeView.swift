import SwiftUI

/// 原稿やprompt本文を再掲せず、clipboard copyの結果だけを伝える一時通知。
struct AIClipboardPromptCopyNoticeView: View {
    let notice: AIClipboardPromptCopyNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImageName)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.headline)
                Text(notice.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(notice.title)。\(notice.message)")

            Button(action: onDismiss) {
                Label("コピー結果を閉じる", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("閉じる")
            .accessibilityLabel("コピー結果を閉じる")
        }
        .padding(12)
        .frame(maxWidth: 400, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var systemImageName: String {
        switch notice.outcome {
        case .success:
            "doc.on.clipboard"
        case .failure:
            "exclamationmark.triangle"
        }
    }
}
