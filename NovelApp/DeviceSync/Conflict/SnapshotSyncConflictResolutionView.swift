import NovelLocalStore
import SwiftUI

struct SnapshotSyncConflictResolutionView: View {
    let conflict: SnapshotSyncConflict
    let isApplying: Bool
    let choose: (SnapshotSyncConflictChoice) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("変更の確認が必要です", systemImage: "exclamationmark.triangle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text("端末の版とサーバーの版を勝手に上書きせず、残す版を選びます。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("競合ID: \(conflict.conflictID.uuidString.prefix(8))")
                    .font(.caption.monospaced())
                Text("端末の版: \(conflict.localSnapshotID.prefix(16))")
                    .font(.caption.monospaced())
                Text("サーバーの版: \(conflict.remoteSnapshotID.isEmpty ? "まだありません" : String(conflict.remoteSnapshotID.prefix(16)))")
                    .font(.caption.monospaced())
            }
            .textSelection(.enabled)

            HStack {
                Button("この端末の版を採用") { choose(.useThisDevice) }
                    .keyboardShortcut(.defaultAction)
                Button("サーバーの版を採用") { choose(.useServer) }
                Button("両方を保持") { choose(.keepBoth) }
                    .disabled(true)
            }
            Text("両方を別作品として保持する操作は、サーバー側のclone処理を準備中です。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if isApplying { ProgressView().controlSize(.small) }
                Button("あとで") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
