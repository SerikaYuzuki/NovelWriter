import NovelSyncV2
import SwiftUI

struct IOSSnapshotHistoryView: View {
    let store: IOSDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var snapshotID: String?
    @State private var restoreSession: IOSDocumentSessionToken?
    @State private var restoreAccountScope: IOSSnapshotSyncV2AccountScope?

    var body: some View {
        List {
            Section("スナップショット履歴") {
                Text(historyAvailabilityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.syncV2HistoryItems.isEmpty {
                    Text("履歴を読み込むと、復元対象を選べます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.syncV2HistoryItems, id: \.occurrenceID) { entry in
                        Button {
                            restoreSession = store.currentDocumentSessionToken
                            restoreAccountScope = store.snapshotSyncV2AccountScope
                            snapshotID = entry.snapshotID.rawValue
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    entry.reason + "・" + entry.createdAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if store.syncV2HistoryCursor != nil {
                        Button("履歴をさらに読み込む") {
                            Task {
                                if let workID = store.syncV2ActiveWorkID {
                                    _ = await store.refreshSnapshotHistory(
                                        for: workID, reset: false
                                    )
                                }
                            }
                        }
                        .disabled(!store.canRefreshSnapshotHistory)
                    }
                }
                Button("履歴を更新") {
                    Task {
                        if let workID = store.syncV2ActiveWorkID {
                            _ = await store.refreshSnapshotHistory(
                                for: workID, reset: true
                            )
                        }
                    }
                }
                .disabled(!store.canRefreshSnapshotHistory)
                Text("復元前の内容も履歴に残します。復元後の同期は接続が戻ると再開します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("スナップショット履歴")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .confirmationDialog("この版を復元しますか？", isPresented: Binding(
            get: { snapshotID != nil },
            set: {
                if !$0 {
                    snapshotID = nil
                }
            }
        )) {
            Button("復元") {
                guard let selected = snapshotID,
                      store.currentDocumentSessionToken == restoreSession,
                      store.snapshotSyncV2AccountScope == restoreAccountScope else { return }
                let session = restoreSession
                let scope = restoreAccountScope
                Task {
                    guard store.currentDocumentSessionToken == session,
                          store.snapshotSyncV2AccountScope == scope else { return }
                    _ = await store.restoreSnapshotSyncV2(snapshotID: selected)
                }
                snapshotID = nil
            }.disabled(!store.canRestoreLocalSnapshot)
            Button("キャンセル", role: .cancel) { snapshotID = nil }
        } message: {
            Text("現在の内容を履歴に残してから、選んだ版へ戻します。")
        }
        .onChange(of: store.currentDocumentSessionToken) { _, _ in snapshotID = nil }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in snapshotID = nil }
        .task {
            if let workID = store.syncV2ActiveWorkID, store.canRefreshSnapshotHistory {
                _ = await store.refreshSnapshotHistory(for: workID, reset: true)
            }
        }
    }

    private var historyAvailabilityLabel: String {
        let local = store.syncV2HistoryLocalAvailability == .available
            ? "端末履歴あり" : "端末履歴なし"
        let online = store.syncV2HistoryOnlineAvailability == .available
            ? "サーバー履歴あり" : "サーバー履歴は未取得"
        return "\(local)・\(online)"
    }
}
