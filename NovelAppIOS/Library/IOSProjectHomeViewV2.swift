import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

struct IOSProjectHomeView: View {
    let store: IOSDocumentStore
    @State private var showsSnapshotHistory = false
    let openWriting: () -> Void
    let openProjectInfo: () -> Void
    let openPlot: () -> Void
    let openCharacters: () -> Void
    let openWorldbuilding: () -> Void
    let openFeedback: () -> Void
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
            Section("執筆") { Button(action: openWriting) { ProjectSectionStyle.writing.label } }
            Section("作品") {
                Button(action: openProjectInfo) { ProjectSectionStyle.projectInfo.label }
                Button(action: openPlot) { ProjectSectionStyle.plot.label }
                    .badge(store.document.flags.count(where: { !$0.isResolved }))
                Button(action: openCharacters) { ProjectSectionStyle.characters.label }
                Button(action: openWorldbuilding) { ProjectSectionStyle.worldbuilding.label }
                Button(action: openFeedback) { ProjectSectionStyle.feedback.label }
                Button(action: openReferences) { ProjectSectionStyle.references.label }
            }
            Section("同期") {
                Text(store.isCurrentWorkParked
                    ? "別アカウントのため保留中"
                    : store.snapshotSyncState?.japaneseLabel
                    ?? (store.snapshotSyncOutcome == .offline
                        ? "端末に保存済み・通信待ち" : "端末に保存済み"))
                    .foregroundStyle(.secondary)
                IOSExplicitSyncButton(store: store)
                if store.snapshotSyncConflict != nil {
                    Text("この端末とサーバーの変更が分かれています")
                        .foregroundStyle(FuminiwaColor.warning.color)
                    Text("残す内容を選んでください。通信が戻ると同期を続けます。")
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
                    Button("サーバーの版を反映") {
                        Task { _ = await store.adoptPendingSnapshotSyncV2() }
                    }
                    .disabled(!store.canExplicitlySyncCurrentWork || store.isExplicitSyncInFlight)
                    Text("サーバーの版は安全な状態なら自動で適用されます。本文変更やIME変換中はこの操作を再試行してください。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section("スナップショット履歴") {
                Button("履歴を見る") { showsSnapshotHistory = true }
                Text("保存した版の確認・復元ができます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(action: openSettings) { ProjectSectionStyle.settings.label }
                Button("作品パッケージを書き出す") { Task { await store.requestExport() } }
                Button("本文と資料を書き出す（ZIP）") { Task { await store.requestExport(readable: true) } }
            }
        }
        .navigationTitle("作品ホーム")
        .sheet(isPresented: $showsSnapshotHistory) {
            NavigationStack { IOSSnapshotHistoryView(store: store) }
        }
        .onChange(of: store.syncV2ActiveWorkID) { _, _ in showsSnapshotHistory = false }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in showsSnapshotHistory = false }
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
        case .keepBoth: "元の作品を保ち、もう一つの作品として残します。"
        }
    }
}
