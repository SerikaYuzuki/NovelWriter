import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

struct IOSProjectHomeView: View {
    let store: IOSDocumentStore
    @State private var snapshotID = ""
    let openWriting: () -> Void
    let openProjectInfo: () -> Void
    let openPlot: () -> Void
    let openCharacters: () -> Void
    let openWorldbuilding: () -> Void
    let openReferences: () -> Void
    let openSettings: () -> Void

    var body: some View {
        List {
            Section {
                Text(store.document.title.isEmpty ? "名称未設定の作品" : store.document.title)
                    .font(.title2.weight(.semibold))
                if !store.document.synopsis.isEmpty {
                    Text(store.document.synopsis).foregroundStyle(.secondary)
                }
            }
            Section("執筆") { Button("本文を書く", action: openWriting) }
            Section("作品") {
                Button("作品情報", action: openProjectInfo)
                Button("プロット", action: openPlot)
                Button("登場人物", action: openCharacters)
                Button("世界観", action: openWorldbuilding)
                Button("資料", action: openReferences)
            }
            Section("同期") {
                Text(store.isCurrentWorkParked
                    ? "別アカウントのため保留中"
                    : store.snapshotSyncState?.japaneseLabel
                    ?? (store.snapshotSyncOutcome == .offline
                        ? "端末に保存済み・通信待ち" : "端末に保存済み"))
                    .foregroundStyle(.secondary)
                Button("今すぐ同期") { Task { _ = await store.synchronizeSnapshotSyncV2() } }
                    .disabled(!store.canExplicitlySyncCurrentWork)
                if let conflict = store.snapshotSyncConflict {
                    Text("競合 (\(conflict.conflictID.uuidString.prefix(8)))")
                        .foregroundStyle(.orange)
                    Text("解決方法を選ぶと、選択したSyncV2操作を端末のSQLiteへ予約します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let displayedSelection = store.snapshotSyncV2DisplayedConflictSelection {
                        ForEach([
                            SyncV2ConflictChoice.useDevice,
                            .useServer,
                            .keepBoth
                        ], id: \.rawValue) { choice in
                            Button(conflictChoiceTitle(choice)) {
                                Task {
                                    _ = await store.resolveSnapshotSyncV2Conflict(
                                        using: choice,
                                        expectedSelection: displayedSelection
                                    )
                                }
                            }
                            .disabled(store.isExplicitSyncInFlight)
                            Text(conflictChoiceDescription(choice))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if case .readyForSafeAdoption = store.snapshotSyncState?.remoteProgress {
                    Button("サーバーの版をこの端末へ適用（安全境界で再試行）") {
                        Task { _ = await store.adoptPendingSnapshotSyncV2() }
                    }
                    .disabled(!store.canExplicitlySyncCurrentWork || store.isExplicitSyncInFlight)
                    Text("サーバーの版は安全な状態なら自動で適用されます。本文変更やIME変換中はこの操作を再試行してください。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section("スナップショット履歴") {
                Text(historyAvailabilityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Snapshot ID", text: $snapshotID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("この版を復元") {
                    let selected = snapshotID
                    Task {
                        if await store.restoreSnapshotSyncV2(snapshotID: selected) {
                            snapshotID = ""
                        }
                    }
                }
                .disabled(snapshotID.isEmpty || !store.canRestoreLocalSnapshot)
                if store.syncV2HistoryItems.isEmpty {
                    Text("履歴を読み込むと、復元対象を選べます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.syncV2HistoryItems, id: \.occurrenceID) { entry in
                        Button {
                            snapshotID = entry.snapshotID.rawValue
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.snapshotID.rawValue)
                                    .font(.caption.monospaced())
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
                        .disabled(!store.canExplicitlySyncCurrentWork)
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
                .disabled(!store.canExplicitlySyncCurrentWork)
                Text("復元は端末のSQLite履歴へ予約され、通信はバックグラウンドで再開します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section { Button("設定", action: openSettings); Button("書き出す") { Task { await store.requestExport() } } }
        }
        .navigationTitle("作品ホーム")
        .task {
            if let workID = store.syncV2ActiveWorkID, store.canExplicitlySyncCurrentWork {
                _ = await store.refreshSnapshotHistory(for: workID, reset: true)
            }
        }
    }

    private func conflictChoiceTitle(_ choice: SyncV2ConflictChoice) -> String {
        switch choice {
        case .useDevice: "この端末の版を使う"
        case .useServer: "サーバーの版を使う"
        case .keepBoth: "両方を残す"
        }
    }

    private func conflictChoiceDescription(_ choice: SyncV2ConflictChoice) -> String {
        switch choice {
        case .useDevice: "この端末の変更をサーバーへ送ります。"
        case .useServer: "サーバーで確認済みの版を、この端末へ適用できます。"
        case .keepBoth: "元の作品を保ち、別WorkIDへ複製します。"
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
