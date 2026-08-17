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
                Text(store.snapshotSyncOutcome == .offline ? "端末に保存済み・通信待ち" : "端末に保存済み")
                    .foregroundStyle(.secondary)
                Button("今すぐ同期") { Task { _ = await store.synchronizeSnapshotSyncV2() } }
                    .disabled(!store.canExplicitlySyncCurrentWork)
                if let conflict = store.snapshotSyncConflict {
                    Text("競合 (\(conflict.conflictID.uuidString.prefix(8)))")
                        .foregroundStyle(.orange)
                }
                if case .readyForSafeAdoption = store.snapshotSyncState?.remoteProgress {
                    Button("サーバーの版をこの端末へ適用") {
                        Task { _ = await store.adoptPendingSnapshotSyncV2() }
                    }
                }
            }
            Section("スナップショット履歴") {
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
                .disabled(snapshotID.isEmpty || !store.canExplicitlySyncCurrentWork)
                Text("復元は端末のSQLite履歴へ予約され、通信はバックグラウンドで再開します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section { Button("設定", action: openSettings); Button("書き出す") { Task { await store.requestExport() } } }
        }
        .navigationTitle("作品ホーム")
    }
}
