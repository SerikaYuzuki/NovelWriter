import NovelSyncV2
import NovelSyncV2Application
import NovelThumbnail
import NovelUI
import SwiftUI

struct IOSProjectHomeView: View {
    let store: IOSDocumentStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                WorkInfoSummary(document: store.document, coverData: store.thumbnailData(ThumbnailOwner(.work, store.document.id)), synopsis: store.document.synopsis)
            }
            Section("執筆") {
                Button(action: openWriting) {
                    Label(store.document.chapters.contains { $0.episodes.contains { !$0.content.isEmpty } } ? "執筆を続ける" : "書き始める", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            Section("作品") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: Spacing.small) {
                    feature("人物", symbol: "person.2", count: store.document.characters.count, action: openCharacters)
                    feature("世界観", symbol: "globe.asia.australia", count: store.document.worldNotes.count, action: openWorldbuilding)
                    feature("プロット", symbol: "rectangle.stack", count: store.document.plotCards.count, action: openPlot)
                    feature("伏線 未回収", symbol: "flag", count: unresolvedCount, action: openPlot)
                    feature("資料", symbol: "paperclip", count: referenceCount, action: openReferences)
                }
                .listRowBackground(FuminiwaColor.paper.color)
                Button(action: openProjectInfo) { ProjectSectionStyle.projectInfo.label }
                Button(action: openFeedback) { ProjectSectionStyle.feedback.label }
            }
            Section("同期") {
                IOSExplicitSyncButton(store: store, status: syncStatus)
                if store.snapshotSyncConflict != nil {
                    VStack(alignment: .leading, spacing: Spacing.small) {
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
                    .padding(Spacing.medium)
                    .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FuminiwaColor.warning.color, lineWidth: 1))
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
            Section("その他") {
                Button("履歴を見る") { showsSnapshotHistory = true }
                Text("保存した版の確認・復元ができます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: openSettings) { ProjectSectionStyle.settings.label }
                Button { Task { await store.requestExport() } } label: {
                    Label("作品を書き出す…", systemImage: "square.and.arrow.up")
                }
                Button { Task { await store.requestExport(readable: true) } } label: {
                    Label("本文と資料を書き出す（ZIP）", systemImage: "square.and.arrow.up")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .onChange(of: store.document.flags, initial: true) { _, _ in unresolvedCount = store.document.flags.count(where: { !$0.isResolved }) }
        .onChange(of: store.attachments, initial: true) { _, _ in referenceCount = store.referenceAttachments.count }
        .navigationTitle("作品ホーム")
        .sheet(isPresented: $showsSnapshotHistory) {
            NavigationStack { IOSSnapshotHistoryView(store: store) }
        }
        .onChange(of: store.syncV2ActiveWorkID) { _, _ in showsSnapshotHistory = false }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in showsSnapshotHistory = false }
    }

    private var syncStatus: SyncV2LibraryStatus {
        let item = store.syncV2LibraryItems.first { $0.workID == store.syncV2ActiveWorkID }
        return SyncV2LibraryStatus.resolve(availability: item?.availability ?? .localOnly,
                                           accountState: item?.accountState ?? .unbound,
                                           remoteHeadConfirmed: item?.remoteHeadConfirmed ?? false,
                                           progress: store.snapshotSyncState?.remoteProgress ?? item?.remoteProgress ?? .idle)
            .delayed(since: store.snapshotSyncState?.oldestUnreceivedAt, now: Date())
    }

    @State private var unresolvedCount = 0
    @State private var referenceCount = 0

    private func feature(_ title: String, symbol: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: Spacing.small)) : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.small))
            layout {
                Label(title, systemImage: symbol).symbolRenderingMode(.hierarchical)
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }
                Text(count, format: .number).font(.title2).monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 72, alignment: .leading)
            .padding(Spacing.medium)
            .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FuminiwaColor.separator.color, lineWidth: 0.5))
        }.buttonStyle(.plain)
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
