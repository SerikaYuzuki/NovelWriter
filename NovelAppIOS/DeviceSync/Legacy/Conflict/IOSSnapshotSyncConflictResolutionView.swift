import NovelLocalStore
import SwiftUI

struct IOSSnapshotSyncConflictResolutionView: View {
    let conflict: SnapshotSyncConflict
    let isApplying: Bool
    let choose: (SnapshotSyncConflictChoice) -> Void
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("競合の確認が必要です", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("端末の版とサーバーの版を勝手に上書きせず、残す版を選びます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        choose(.useThisDevice)
                    } label: {
                        Label("この端末の版を採用", systemImage: "iphone")
                    }
                    .disabled(isApplying)

                    Button {
                        choose(.useServer)
                    } label: {
                        Label("サーバーの版を採用", systemImage: "server.rack")
                    }
                    .disabled(isApplying)

                    Button {
                        choose(.keepBoth)
                    } label: {
                        Label("両方を保持", systemImage: "square.on.square")
                    }
                    .disabled(true)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("選択")
                } footer: {
                    Text("両方を別作品として保持する操作は、サーバー側のclone処理を準備中です。")
                }

                Section {
                    LabeledContent("競合ID", value: String(conflict.conflictID.uuidString.prefix(8)))
                    LabeledContent("端末の版", value: String(conflict.localSnapshotID.prefix(12)))
                    LabeledContent(
                        "サーバーの版",
                        value: conflict.remoteSnapshotID.isEmpty
                            ? "まだありません"
                            : String(conflict.remoteSnapshotID.prefix(12))
                    )
                } header: {
                    Text("確認情報")
                }
            }
            .navigationTitle("変更を確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("あとで") { dismiss() }
                        .disabled(isApplying)
                }
                if isApplying {
                    ToolbarItem(placement: .topBarTrailing) {
                        ProgressView()
                    }
                }
            }
        }
    }
}
