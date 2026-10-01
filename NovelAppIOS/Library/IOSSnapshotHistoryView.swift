import NovelSyncV2
import SwiftUI

struct IOSSnapshotHistoryView: View {
    let store: IOSDocumentStore
    @Environment(\.dismiss) private var dismiss
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
                        VStack(alignment: .leading) {
                            Text(entry.displayReason + "・" + entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                            if let application = store.snapshotSyncV2Application,
                               let workID = store.syncV2ActiveWorkID {
                                let session = store.currentDocumentSessionToken
                                let scope = store.snapshotSyncV2AccountScope
                                HistoryFetchControls(application: application, workID: workID, snapshotID: entry.snapshotID,
                                                     announcesStatus: entry.occurrenceID == store.syncV2HistoryItems.first?.occurrenceID) {
                                    guard store.currentDocumentSessionToken == session,
                                          store.snapshotSyncV2AccountScope == scope else { return }
                                    _ = await store.restoreSnapshotSyncV2(snapshotID: entry.snapshotID.rawValue)
                                }
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
        .onChange(of: store.currentDocumentSessionToken) { _, _ in dismiss() }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in dismiss() }
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
