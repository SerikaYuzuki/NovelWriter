import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

struct LibraryPane: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @State private var pendingRename: StartupLibraryWork?
    @State private var renameSession: DocumentSessionToken?
    @State private var renameAccountScope: SnapshotSyncV2AccountScopeToken?
    @State private var renameTitle = ""
    @State private var renamingIDs: Set<UUID> = []
    @State private var renameFailed = false
    @State private var pendingDeletion: StartupLibraryWork?
    @State private var deletionAccountScope: SnapshotSyncV2AccountScopeToken?
    @State private var deletingIDs: Set<UUID> = []
    @State private var showingHistory = false
    @State private var selection: UUID?
    @State private var searchText = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("作品一覧")
                    .font(.headline)
                Spacer()
                Button("新規", systemImage: "plus") {
                    documentPanelPresenter.presentNewDocument()
                }
                .labelStyle(.iconOnly)
                .help("新しい作品")
                Button("取り込む", systemImage: "square.and.arrow.down") {
                    documentPanelPresenter.presentOpenPanel()
                }
                .labelStyle(.iconOnly)
                .help("作品を取り込む")
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshSnapshotLibrary() }
                }
                .labelStyle(.iconOnly)
                .help("作品一覧を更新")
                Button("履歴", systemImage: "clock.arrow.circlepath") {
                    Task {
                        await appState.refreshSnapshotHistory()
                        showingHistory = true
                    }
                }
                .labelStyle(.iconOnly)
                .help("スナップショット履歴")
            }
            .padding(.horizontal, 12)
            TextField("作品を検索", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
            List(selection: $selection) {
                Section {
                    ForEach(filteredWorks) { work in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: work))
                                .foregroundStyle(color(for: work))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(work.title).lineLimit(1)
                                Text(label(for: work))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if renamingIDs.contains(work.id) {
                                ProgressView().controlSize(.small).accessibilityLabel("作品名を変更中")
                            }
                        }
                        .tag(work.id)
                        .contextMenu {
                            Button("開く") { open(work) }
                                .disabled(!canOpen(work))
                            renameButton(work)
                            deleteButton(work)
                        }
                        .accessibilityIdentifier("library.work.\(work.id.uuidString)")
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: searchText) { _, _ in
                if !filteredWorks.contains(where: { $0.id == selection }) {
                    selection = nil
                }
            }
            .overlay {
                if filteredWorks.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "最初の作品を書きましょう" : "作品が見つかりません",
                        systemImage: searchText.isEmpty ? "book.closed" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "「新規」からオフラインでも始められます。" : "検索する言葉を変えてください。")
                    )
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let work = works.first(where: { ids.contains($0.id) }) {
                    Button("開く") { open(work) }.disabled(!canOpen(work))
                    renameButton(work)
                    deleteButton(work)
                }
            } primaryAction: { ids in
                if let work = works.first(where: { ids.contains($0.id) }) {
                    open(work)
                }
            }
            HStack {
                AccountAccessView()
                Spacer()
                Button("開く") {
                    if let work = works.first(where: { $0.id == selection }) {
                        open(work)
                    }
                }
                .disabled(!works.contains { $0.id == selection && canOpen($0) })
            }
            .padding(.horizontal, 12)
            Text(connectionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .alert("作品名を変更", isPresented: Binding(
            get: { pendingRename != nil },
            set: {
                if !$0 {
                    pendingRename = nil
                }
            }
        )) {
            TextField("作品名", text: $renameTitle)
            Button("変更") {
                guard let work = pendingRename, let session = renameSession,
                      let scope = renameAccountScope else { return }
                let title = renameTitle
                renamingIDs.insert(work.id)
                Task {
                    renameFailed = await !(appState.renameLibraryWork(
                        work, title: title, expectedSession: session, accountScope: scope
                    ))
                    renamingIDs.remove(work.id)
                }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("キャンセル", role: .cancel) {}
        }
        .alert("作品名を変更できませんでした", isPresented: $renameFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("作品やアカウントが切り替わっていないか、接続状態を確認して再試行してください。")
        }
        .alert("作品を完全に削除しますか？", isPresented: Binding(get: { pendingDeletion != nil }, set: {
            if !$0 {
                pendingDeletion = nil
            }
        })) {
            Button("削除", role: .destructive) {
                guard let work = pendingDeletion, let accountScope = deletionAccountScope else { return }
                deletingIDs.insert(work.id)
                Task {
                    if await appState.deleteLibraryWork(work, accountScope: accountScope) {
                        selection = nil
                    }
                    deletingIDs.remove(work.id)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(pendingDeletion?.title ?? "")」の本文・履歴・添付ファイルを、この端末と同期先サーバーから削除します。元に戻せません。別の作品として作ったコピーは残ります。")
        }
        .frame(minWidth: 220)
        .sheet(isPresented: $showingHistory) {
            SnapshotHistorySheet {
                showingHistory = false
            }
        }
    }

    private func canOpen(_ work: StartupLibraryWork) -> Bool {
        work.isOpenable && !renamingIDs.contains(work.id)
            && !appState.snapshotSyncPendingDeletionWorkIDs.contains(work.workID)
    }

    private func renameButton(_ work: StartupLibraryWork) -> some View {
        Button("作品名を変更…", systemImage: "pencil") {
            renameTitle = work.title
            renameSession = appState.documentSessionToken
            renameAccountScope = appState.snapshotSyncV2AccountScopeToken
            pendingRename = work
        }
        .disabled(!canOpen(work))
    }

    private func deleteButton(_ work: StartupLibraryWork) -> some View {
        Button("削除…", systemImage: "trash", role: .destructive) {
            deletionAccountScope = appState.snapshotSyncV2AccountScopeToken
            pendingDeletion = work
        }
        .disabled(deletingIDs.contains(work.id) || work.availability == .parked || work.availability == .excluded)
    }

    private func open(_ work: StartupLibraryWork) {
        guard canOpen(work) else { return }
        Task {
            if await appState.openLibraryWork(work) {
                openWindow(id: "workbench")
                dismissWindow(id: "library")
            }
        }
    }

    private var filteredWorks: [StartupLibraryWork] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? works : works.filter { $0.title.localizedStandardContains(query) }
    }

    private var works: [StartupLibraryWork] {
        if !appState.snapshotSyncLibraryWorks.isEmpty {
            return appState.snapshotSyncLibraryWorks
        }
        if case let .documentSelection(context) = appState.startupState {
            return context.works
        }
        return []
    }

    private var connectionLabel: String {
        switch appState.lastStartupLibraryConnection {
        case .available: "サーバーに接続できます"
        case .offline: "オフライン・接続時再開"
        case .accountRequired: "サインインせず、この端末で執筆できます"
        case .differentAccount: "別のアカウントのため保留中"
        case let .unavailable(message): message
        }
    }

    private func icon(for work: StartupLibraryWork) -> String {
        switch work.remoteProgress {
        case .needsChoice:
            return "exclamationmark.triangle"
        case .readyForSafeAdoption:
            return "arrow.down.circle"
        case .pending, .syncing, .retryable:
            return "arrow.triangle.2.circlepath"
        case .offline:
            return "wifi.slash"
        case .failed, .receiptMismatch:
            return "exclamationmark.circle"
        default:
            break
        }
        return switch work.availability {
        case .remoteOnly: "server.rack.and.arrow.down"
        case .cached: "externaldrive"
        case .pending: "arrow.triangle.2.circlepath"
        case .conflict: "exclamationmark.triangle"
        case .parked, .excluded: "lock"
        case .local: "internaldrive"
        }
    }

    private func color(for work: StartupLibraryWork) -> Color {
        if case .readyForSafeAdoption = work.remoteProgress {
            return .blue
        }
        return switch work.availability {
        case .conflict: Color.orange
        case .remoteOnly: Color.blue
        case .parked, .excluded: Color.secondary
        default: Color.secondary
        }
    }

    private func label(for work: StartupLibraryWork) -> String {
        if appState.snapshotSyncPendingDeletionWorkIDs.contains(work.workID) {
            return "削除待ち・接続時に再試行"
        }
        switch work.remoteProgress {
        case .pending, .syncing, .retryable:
            return "同期待ち"
        case .offline:
            return "オフライン・接続時再開"
        case .authenticationRequired:
            return "サインインすると同期します"
        case .needsChoice:
            return "競合・確認が必要"
        case .readyForSafeAdoption:
            return "サーバーの版を適用できます"
        case .parkedDifferentAccount, .fenceChanged, .quarantined:
            return "別のアカウントのため保留中"
        case .failed, .receiptMismatch:
            return "同期できませんでした"
        case .idle, .noChanges:
            break
        }
        return switch work.availability {
        case .local: "この端末"
        case .cached: "この端末・同期済み"
        case .remoteOnly: "サーバー・未ダウンロード"
        case .pending: "同期待ち"
        case .conflict: "競合・確認が必要"
        case .parked: "別のアカウントのため保留中"
        case .excluded: "表示対象外"
        }
    }
}

private struct SnapshotHistorySheet: View {
    @Environment(AppState.self) private var appState
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スナップショット履歴")
                .font(.title2.weight(.semibold))
            if appState.snapshotSyncHistory.isEmpty {
                ContentUnavailableView(
                    "履歴はありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("この端末の履歴とオンライン履歴を、利用できる範囲で表示します。")
                )
            } else {
                List(appState.snapshotSyncHistory, id: \.occurrenceID) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayReason)
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.source == .local ? "端末" : "オンライン")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if entry.pinned {
                            Label("保持", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("復元") {
                            Task {
                                if await appState.restoreSnapshotV2(snapshotID: entry.snapshotID) {
                                    dismiss()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Button("閉じる", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 300)
        .accessibilityIdentifier("snapshotSyncV2.historySheet")
    }
}
