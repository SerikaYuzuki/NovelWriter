import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelUI
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
    @State private var showingProtection = false
    @State private var selection: UUID?
    @State private var searchText = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("作品一覧")
                    .font(.headline)
                Spacer()
                Button("新規", systemImage: "plus") {
                    documentPanelPresenter.presentNewDocument()
                }
                .labelStyle(.iconOnly)
                .help("新しい作品")
                .disabled(!appState.permitsNewDocument)
                Button("取り込む", systemImage: "square.and.arrow.down") {
                    documentPanelPresenter.presentOpenPanel()
                }
                .labelStyle(.iconOnly)
                .help("作品を取り込む")
                Button("更新", systemImage: "arrow.clockwise") {
                    Task {
                        await appState.refreshSnapshotLibrary()
                        await appState.refreshSnapshotRemoteCatalog()
                    }
                }
                .labelStyle(.iconOnly)
                .help("作品一覧を更新")
                Button("復元", systemImage: "archivebox") { showingProtection = true }
                    .labelStyle(.iconOnly).help("別作品として復元")
                Button("履歴", systemImage: "clock.arrow.circlepath") {
                    Task {
                        await appState.refreshSnapshotHistory()
                        showingHistory = true
                    }
                }
                .labelStyle(.iconOnly)
                .help("スナップショット履歴")
            }
            .padding(.horizontal, Spacing.medium)
            TextField("作品を検索", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Spacing.medium)
            if let failure = appState.snapshotSyncLibraryFailure ?? appState.snapshotSyncLibraryLocalFailure {
                StatusLabel(SyncV2LibraryPresentation.isOffline(failure)
                    ? SyncV2LibraryPresentation.offlineNotice : remoteOnlyOpenErrorMessage(failure),
                    systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                    tone: SyncV2LibraryPresentation.isOffline(failure) ? .offline : .danger)
                    .font(FuminiwaType.rowSecondary)
                    .padding(.horizontal, Spacing.medium)
            }
            List(selection: $selection) {
                Section {
                    ForEach(filteredWorks) { work in
                        HStack(spacing: Spacing.small) {
                            // Leading slot reserved for a future cover thumbnail.
                            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                                Text(work.title).lineLimit(1)
                                if appState.snapshotSyncV2RemoteOnlyOpeningWorkID == work.workID,
                                   let startedAt = appState.snapshotSyncV2RemoteOnlyOpenStartedAt {
                                    LibraryImportProgress(startedAt: startedAt,
                                                          longImportNotice: SyncV2LibraryPresentation.longImportNotice)
                                } else {
                                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                                        StatusLabel(status(for: work).text, systemImage: status(for: work).symbol,
                                                    tone: StatusTone(rawValue: status(for: work).tone.rawValue) ?? .secondary)
                                            .font(FuminiwaType.rowSecondary)
                                            .accessibilityLabel(status(for: work).text)
                                    }
                                }
                            }
                            Spacer()
                            if renamingIDs.contains(work.id) {
                                ProgressView().controlSize(.small).accessibilityLabel("作品名を変更中")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(rowHint(work))
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
                    if appState.startupState == .loading || appState.snapshotSyncLibraryIsLoading {
                        ContentUnavailableView("作品一覧を読み込み中…", systemImage: "arrow.clockwise")
                    } else if let failure = appState.snapshotSyncLibraryFailure ?? appState.snapshotSyncLibraryLocalFailure {
                        ContentUnavailableView(SyncV2LibraryPresentation.isOffline(failure) ? "オフラインです" : "作品一覧を読み込めませんでした",
                                               systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                                               description: Text("「更新」からもう一度読み込めます。端末内では「新規」から書き始められます。"))
                    } else {
                        ContentUnavailableView(
                            searchText.isEmpty ? "最初の作品を書きましょう" : "作品が見つかりません",
                            systemImage: searchText.isEmpty ? "book.closed" : "magnifyingglass",
                            description: Text(searchText.isEmpty ? "「新規」からオフラインでも始められます。" : "検索する言葉を変えてください。")
                        )
                    }
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
            .padding(.horizontal, Spacing.medium)
            Text(connectionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.medium)
                .padding(.bottom, Spacing.small)
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
            Text("「\(pendingDeletion?.title ?? "")」を一覧から削除します。同期した作品のサーバー受領済みデータは1年間保管されます。この端末だけの作品は元に戻せません。")
        }
        .sheet(isPresented: $showingProtection) {
            if let application = appState.snapshotSyncV2Application {
                ProtectedWorksView(application: application,
                                   contextID: String(describing: appState.snapshotSyncV2AccountScopeToken)) {
                    await appState.refreshSnapshotLibrary()
                }
            }
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
            && !(work.availability == .remoteOnly && appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
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
            if await appState.openLibraryWork(work),
               appState.currentSnapshotSyncV2WorkID == work.workID, appState.startupState.isReady {
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
        case .unavailable: "作品一覧を読み込めませんでした"
        }
    }

    private func status(for work: StartupLibraryWork) -> SyncV2LibraryStatus {
        if appState.snapshotSyncPendingDeletionWorkIDs.contains(work.workID) {
            return .init(text: "削除待ち・接続時に再試行", symbol: "clock", tone: .secondary)
        }
        return work.status
    }

    private func rowHint(_ work: StartupLibraryWork) -> String {
        if appState.snapshotSyncV2RemoteOnlyOpeningWorkID == work.workID {
            return "この作品を取り込み中です"
        }
        if renamingIDs.contains(work.id) {
            return "作品名を変更中です"
        }
        if work.availability == .remoteOnly {
            return appState.snapshotSyncV2RemoteOnlyOpeningWorkID == nil
                ? SyncV2LibraryPresentation.remoteOnlyHint : SyncV2LibraryPresentation.importBusyReason
        }
        return ""
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
