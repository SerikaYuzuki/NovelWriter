import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import NovelWorkspaceUI
import SwiftUI

struct IOSSnapshotHistoryView: View {
    @Environment(WorkspaceModel.self) private var workspace
    let store: IOSDocumentStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("履歴") {
                Text(historyAvailabilityLabel)
                    .font(.caption)
                    .foregroundStyle(FuminiwaColor.textSecondary.color)
                if workspace.historyItems.isEmpty {
                    Text("履歴を読み込むと、復元対象を選べます。")
                        .font(.caption)
                        .foregroundStyle(FuminiwaColor.textSecondary.color)
                }
            }
            if !workspace.historyItems.isEmpty {
                SnapshotHistorySections(items: workspace.historyItems, application: store.snapshotSyncV2Application, workID: workspace.activeWorkID) { entry in
                    if let application = store.snapshotSyncV2Application,
                       let workID = workspace.activeWorkID {
                        let session = store.currentDocumentSessionToken
                        let scope = store.snapshotSyncV2AccountScope
                        let newest = entry.occurrenceID == workspace.historyItems.first?.occurrenceID
                        HistoryFetchControls(
                            application: application, workID: workID, snapshotID: entry.snapshotID,
                            rowDate: entry.createdAt, rowKind: HistoryPresentation().subtitle(entry),
                            historyItem: entry, userDefaults: store.userDefaults,
                            announcesStatus: newest
                        ) {
                            guard store.currentDocumentSessionToken == session,
                                  store.snapshotSyncV2AccountScope == scope else { return }
                            _ = await store.restoreSnapshotSyncV2(snapshotID: entry.snapshotID.rawValue)
                        }
                        .surfaceCard()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: Spacing.extraSmall, leading: Spacing.outer,
                                                  bottom: Spacing.extraSmall, trailing: Spacing.outer))
                    } else {
                        SnapshotHistoryLabel(item: entry, userDefaults: store.userDefaults)
                    }
                }
                if store.syncV2HistoryCursor != nil {
                    Button("履歴をさらに読み込む") {
                        Task {
                            if let workID = workspace.activeWorkID {
                                _ = await store.refreshSnapshotHistory(
                                    for: workID, reset: false
                                )
                            }
                        }
                    }
                    .disabled(!store.canRefreshSnapshotHistory)
                }
            }
            Section {
                Button("履歴を更新") {
                    Task {
                        if let workID = workspace.activeWorkID {
                            _ = await store.refreshSnapshotHistory(
                                for: workID, reset: true
                            )
                        }
                    }
                }
                .disabled(!store.canRefreshSnapshotHistory)
                Text("復元前の内容も履歴に残します。復元後の同期は接続が戻ると再開します。")
                    .font(.caption)
                    .foregroundStyle(FuminiwaColor.textSecondary.color)
            }
            .listRowBackground(FuminiwaColor.paper.color)
            .listRowSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .navigationTitle("履歴")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .onChange(of: store.currentDocumentSessionToken) { _, _ in dismiss() }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in dismiss() }
        .task {
            if let workID = workspace.activeWorkID, store.canRefreshSnapshotHistory {
                _ = await store.refreshSnapshotHistory(for: workID, reset: true)
            }
        }
    }

    private var historyAvailabilityLabel: String {
        switch (store.syncV2HistoryLocalAvailability == .available,
                store.syncV2HistoryOnlineAvailability == .available) {
        case (true, true): "この端末とサーバーの履歴"
        case (true, false): "この端末の履歴（サーバーの履歴は未取得）"
        case (false, true): "サーバーの履歴"
        case (false, false): "履歴を読み込んでいます"
        }
    }
}
