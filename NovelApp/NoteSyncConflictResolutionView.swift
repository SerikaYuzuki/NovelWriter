import NovelSync
import SwiftUI

struct NoteSyncConflictPresentation: Equatable, Sendable {
    let workTitle: String
    let heading = "変更の確認が必要です"
    let message: String
    let footnote = "閉じても編集は続けられます。選ぶまでは両方の内容を残します。"
    let localActionTitle = "この端末の内容を使う"
    let remoteActionTitle = "iCloudの内容を使う"
    let bothActionTitle = "両方を別作品として残す"

    init(workTitle: String) {
        self.workTitle = workTitle
        let display = workTitle.isEmpty ? "名称未設定の作品" : workTitle
        message = "「\(display)」は、この端末とiCloudの両方で変わっています。内容を一つにまとめず、残す側を選べます。"
    }
}

/// 通常のcloud衝突用の短い3択。統合案は出さず、内部語も出さない。
struct NoteSyncConflictResolutionView: View {
    let presentation: NoteSyncConflictPresentation
    let isApplying: Bool
    let choose: (NoteSyncConflictChoice) -> Void
    let reviewLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(presentation.heading, systemImage: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(presentation.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(presentation.footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("あとで", action: reviewLater)
                    .buttonStyle(.bordered)
                    .accessibilityHint("選ばずに比較画面を閉じます")
                    .accessibilityIdentifier("noteSync.reviewLater")
            }

            VStack(alignment: .leading, spacing: 8) {
                Button(presentation.localActionTitle) { choose(.keepLocal) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("noteSync.keepLocal")
                Button(presentation.remoteActionTitle) { choose(.keepRemote) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("noteSync.keepRemote")
                Button(presentation.bothActionTitle) { choose(.keepBoth) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("noteSync.keepBoth")
            }
            .disabled(isApplying)

            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("選択した内容を保存しています")
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 280)
        .accessibilityIdentifier("noteSync.review")
    }
}
