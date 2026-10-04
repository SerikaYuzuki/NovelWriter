import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import NovelWorkspaceUI
import SwiftUI

struct LibraryPane: View {
    var observesImports = true
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @AppStorage("library.display") private var display = ShelfDisplay.grid
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var usesGrid: Bool {
        display == .grid && !dynamicTypeSize.isAccessibilitySize
    }

    @State private var pendingRename: StartupLibraryWork?
    @State private var renameSession: DocumentSessionToken?
    @State private var renameAccountScope: SnapshotSyncV2AccountScopeToken?
    @State private var renameTitle = ""
    @State private var renamingIDs: Set<UUID> = []
    @State private var renameFailed = false
    @State private var pendingDeletion: StartupLibraryWork?
    @State private var deletionAccountScope: SnapshotSyncV2AccountScopeToken?
    @State private var deletingIDs: Set<UUID> = []
    @State private var showingProtection = false
    @FocusState private var focusedWorkID: UUID?
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var pendingImportOpen: StartupLibraryWork?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Image("FuminiwaBookSprout").resizable().scaledToFit()
                    .frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                    Text("ふみにわ").font(.largeTitle.bold())
                    Text("書きたい物語を、ここから。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.medium)
            TextField(LibraryText.search, text: $searchText)
                .focused($searchFocused)
                .accessibilityIdentifier("library.search")
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
            if let failure = appState.snapshotSyncLibraryOpenFailure {
                StatusLabel(remoteOnlyOpenErrorMessage(failure), systemImage: "exclamationmark.circle", tone: .danger)
                    .font(FuminiwaType.rowSecondary)
                    .padding(.horizontal, Spacing.medium)
                    .accessibilityIdentifier("library.openFailure")
            }
            Group {
                if usesGrid {
                    shelfGrid
                } else {
                    List(selection: $selection) {
                        ForEach(filteredWorks) { work in workRow(work) }
                    }.listStyle(.plain)
                        .scrollContentBackground(.hidden)
                }
            }
            .onChange(of: searchText) { _, _ in
                if !filteredWorks.contains(where: { $0.id == selection }) {
                    selection = nil
                }
            }
            .overlay {
                if filteredWorks.isEmpty {
                    if appState.startupState == .loading || appState.snapshotSyncLibraryIsLoading {
                        ProgressView(LibraryText.loading)
                    } else if let failure = appState.snapshotSyncLibraryFailure ?? appState.snapshotSyncLibraryLocalFailure {
                        ContentUnavailableView(SyncV2LibraryPresentation.isOffline(failure) ? LibraryText.offline : LibraryText.loadFailed,
                                               systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                                               description: Text(LibraryText.retryMac))
                    } else {
                        if searchText.isEmpty {
                            ContentUnavailableView {
                                Image("FuminiwaBookSprout").resizable().scaledToFit()
                                    .frame(width: 144, height: 144).accessibilityHidden(true)
                                Text(LibraryText.empty)
                            } description: {
                                Text(LibraryText.emptyMac)
                            } actions: {
                                Button("新しい作品…") { documentPanelPresenter.presentNewDocument() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!appState.permitsNewDocument)
                                Button(LibraryText.importWork) { documentPanelPresenter.presentOpenPanel() }
                                    .disabled(!appState.permitsDocumentImport)
                            }
                        } else {
                            ContentUnavailableView(LibraryText.noSearchResults, systemImage: "magnifyingglass",
                                                   description: Text(LibraryText.searchHint))
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let work = works.first(where: { ids.contains($0.id) }) {
                    Button("開く") { open(work) }.disabled(!canOpen(work))
                    historyButton(work)
                    importMenu(work)
                    takeButton(work)
                    renameButton(work)
                    deleteButton(work)
                }
            } primaryAction: { ids in
                if let work = works.first(where: { ids.contains($0.id) }) {
                    open(work)
                }
            }
            if appState.snapshotSyncRemoteCatalogNextCursor != nil {
                Button(LibraryText.loadMore) {
                    Task { await appState.refreshSnapshotRemoteCatalog(loadMore: true) }
                }
                .disabled(appState.snapshotSyncLibraryIsLoading)
                .frame(maxWidth: .infinity)
            }
            Divider()
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
        .padding(.top, Spacing.medium)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新しい作品…", systemImage: "plus") { documentPanelPresenter.presentNewDocument() }
                    .disabled(!appState.permitsNewDocument)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(LibraryText.importWork, systemImage: "square.and.arrow.down") { documentPanelPresenter.presentOpenPanel() }
                    .disabled(!appState.permitsDocumentImport)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task {
                        await appState.refreshSnapshotLibrary()
                        await appState.refreshSnapshotRemoteCatalog()
                    }
                }.help("作品一覧を更新")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("別作品として復元…", systemImage: "archivebox") { showingProtection = true }
            }
            ToolbarItem(placement: .primaryAction) { ShelfDisplayPicker(selection: $display) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLibrarySearch)) { _ in
            searchFocused = true
        }
        .background(FuminiwaColor.paper.color)
        .alert(LibraryText.rename, isPresented: Binding(
            get: { pendingRename != nil },
            set: {
                if !$0 {
                    pendingRename = nil
                }
            }
        )) {
            TextField(LibraryText.title, text: $renameTitle)
            Button(LibraryText.change) {
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
            Button(LibraryText.cancel, role: .cancel) {}
        }
        .alert(LibraryText.renameFailed, isPresented: $renameFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LibraryText.renameRetry)
        }
        .alert(LibraryText.deleteConfirmation, isPresented: Binding(get: { pendingDeletion != nil }, set: {
            if !$0 {
                pendingDeletion = nil
            }
        })) {
            Button(LibraryText.delete, role: .destructive) {
                guard let work = pendingDeletion, let accountScope = deletionAccountScope else { return }
                deletingIDs.insert(work.id)
                Task {
                    if await appState.deleteLibraryWork(work, accountScope: accountScope) {
                        selection = nil
                    }
                    deletingIDs.remove(work.id)
                }
            }
            Button(LibraryText.cancel, role: .cancel) {}
        } message: {
            Text(LibraryText.deletionMessage(title: pendingDeletion?.title ?? ""))
        }
        .task(id: appState.snapshotSyncV2AccountScopeToken) {
            guard observesImports, let application = appState.snapshotSyncV2Application else { return }
            for await _ in await application.stateChanges() {
                guard !Task.isCancelled else { return }
                await appState.refreshSnapshotLibrary()
            }
        }
        .sheet(isPresented: $showingProtection) {
            if let application = appState.snapshotSyncV2Application {
                ProtectedWorksView(application: application,
                                   contextID: String(describing: appState.snapshotSyncV2AccountScopeToken)) {
                    await appState.refreshSnapshotLibrary()
                }
            }
        }
        #if FUMINIWA_TEST_COMPOSITION
        .task {
                if ProcessInfo.processInfo.arguments.contains("--library-preview=import-cancel") {
                    pendingImportOpen = appState.snapshotSyncLibraryWorks.last
                }
            }
        #endif
            .task(id: appState.snapshotSyncV2AccountScopeToken) {
                if observesImports {
                    await appState.observeLibraryImports()
                }
            }
            .confirmationDialog(LibraryText.cancelImportConfirmation, isPresented: Binding(
                get: { pendingImportOpen != nil }, set: {
                    if !$0 {
                        pendingImportOpen = nil
                    }
                }
            ), titleVisibility: .visible) {
                if let work = pendingImportOpen {
                    Button(LibraryText.cancelImportAndOpen) {
                        pendingImportOpen = nil
                        Task { await appState.cancelLibraryImport(); performOpen(work) }
                    }
                }
                Button(LibraryText.cancel, role: .cancel) { pendingImportOpen = nil }
            }
            .frame(minWidth: 220)
    }
}

private extension LibraryPane {
    private var shelfGrid: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Spacing.outer, alignment: .top)], spacing: Spacing.outer) {
                        ForEach(filteredWorks) { work in
                            workRow(work)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.small)
                                .background(selection == work.id ? FuminiwaColor.accentMuted.color : FuminiwaColor.surface.color,
                                            in: RoundedRectangle(cornerRadius: Radius.card))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(work) }
                                .onTapGesture { selection = work.id; focusedWorkID = work.id }
                                .accessibilityAddTraits(selection == work.id ? .isSelected : [])
                                .accessibilityAction(named: "開く") { open(work) }
                                .focusable()
                                .focused($focusedWorkID, equals: work.id)
                                .id(work.id)
                        }
                    }.padding(Spacing.medium)
                }
                .onChange(of: focusedWorkID) { _, id in
                    if let id {
                        selection = id; proxy.scrollTo(id)
                    }
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let columns = max(1, Int((geometry.size.width - 2 * Spacing.medium + Spacing.outer) / (160 + Spacing.outer)))
                    let offset = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : press.key == .upArrow ? -columns : columns
                    guard !filteredWorks.isEmpty else { return .ignored }
                    let index = filteredWorks.firstIndex { $0.id == selection } ?? 0
                    focusedWorkID = filteredWorks[min(max(index + offset, 0), filteredWorks.count - 1)].id
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let work = works.first(where: { $0.id == selection }) else { return .ignored }
                    open(work)
                    return .handled
                }
            }
        }
    }

    private var rowLayout: AnyLayout {
        usesGrid ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.small)) : AnyLayout(HStackLayout(spacing: Spacing.small))
    }

    private func workRow(_ work: StartupLibraryWork) -> some View {
        rowLayout {
            LazyCoverThumbnail(title: work.title, identity: "\(work.workID)-\(appState.snapshotSyncV2AccountScopeToken)-\(work.localGeneration ?? 0)", size: usesGrid ? 120 : 32) {
                guard work.availability != .remoteOnly else { return nil }
                let account = appState.snapshotSyncV2AccountScopeToken
                let bytes = try? await appState.snapshotSyncV2Application?.localCoverThumbnail(workID: work.workID)
                guard account == appState.snapshotSyncV2AccountScopeToken else { return nil }
                return bytes
            }
            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                Text(work.title).font(usesGrid ? FuminiwaType.shelfTitle : .body).truncationMode(.tail).lineLimit(usesGrid ? 2 : 1)
                if appState.snapshotSyncV2RemoteOnlyOpeningWorkID == work.workID || appState.libraryPrefetchWorkID == work.workID,
                   let startedAt = appState.snapshotSyncV2RemoteOnlyOpenStartedAt {
                    LibraryImportProgress(startedAt: startedAt,
                                          longImportNotice: SyncV2LibraryPresentation.longImportNotice,
                                          label: (appState.libraryImportPhases[work.workID] ?? ImportPhase()).japaneseLabel,
                                          fraction: appState.libraryImportPhases[work.workID]?.stage == .receiving
                                              ? appState.libraryImportPhases[work.workID]?.fraction : nil,
                                          accessibilityValue: (appState.libraryImportPhases[work.workID] ?? ImportPhase()).accessibilityValue, compact: usesGrid)
                    Button(usesGrid ? "中止" : "取り込みを中止") { Task { await appState.cancelLibraryImport() } }
                        .buttonStyle(.borderless)
                } else if let failure = appState.libraryImportFailures[work.workID] {
                    StatusLabel(SyncV2LibraryPresentation.importFailure(failure), systemImage: "exclamationmark.circle", tone: .danger)
                    Button("再試行") { appState.takeOntoDevice(workID: work.workID, title: work.title) }
                        .tint(FuminiwaColor.accent.color)
                        .help(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                        .accessibilityHint(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                        .buttonStyle(.borderless)
                        .disabled(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
                } else {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        StatusLabel(status(for: work).text, systemImage: status(for: work).symbol,
                                    tone: StatusTone(rawValue: status(for: work).tone.rawValue) ?? .secondary)
                            .font(FuminiwaType.rowSecondary)
                            .accessibilityLabel(status(for: work).text)
                    }
                }
            }
            if let note = work.historyBackfillNote, let application = appState.snapshotSyncV2Application {
                HistoryFetchControls(application: application, workID: work.workID, snapshotID: nil, progressNote: note, userDefaults: appState.userDefaults)
                    .id(appState.snapshotSyncV2AccountScopeToken)
            }
            if !usesGrid {
                Spacer()
            }
            if renamingIDs.contains(work.id) {
                ProgressView().controlSize(.small).accessibilityLabel("作品名を変更中")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(rowHint(work))
        .contextMenu {
            Button("開く") { open(work) }
                .disabled(!canOpen(work))
            historyButton(work)
            importMenu(work)
            takeButton(work)
            renameButton(work)
            deleteButton(work)
        }
        .accessibilityIdentifier("library.work.\(work.id.uuidString)")
        .tag(work.id)
    }

    @ViewBuilder private func importMenu(_ work: StartupLibraryWork) -> some View {
        if appState.libraryPrefetchWorkID == work.workID || appState.snapshotSyncV2RemoteOnlyOpeningWorkID == work.workID {
            Text(LibraryImportProgress.hint(SyncV2LibraryPresentation.longImportNotice))
            Button("取り込みを中止") { Task { await appState.cancelLibraryImport() } }
        } else if appState.libraryImportFailures[work.workID] != nil {
            Button("再試行") { appState.takeOntoDevice(workID: work.workID, title: work.title) }
                .tint(FuminiwaColor.accent.color)
                .help(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                .accessibilityHint(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                .disabled(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
        }
    }

    private func historyButton(_ work: StartupLibraryWork) -> some View {
        Button("履歴…", systemImage: "clock.arrow.circlepath") {
            let account = appState.snapshotSyncV2AccountScopeToken
            Task {
                guard await appState.openLibraryWork(work),
                      appState.currentSnapshotSyncV2WorkID == work.workID,
                      appState.matchesSnapshotSyncV2AccountScope(account) else { return }
                let session = appState.documentSessionToken
                await appState.refreshSnapshotHistory()
                guard appState.documentSessionToken == session,
                      appState.matchesSnapshotSyncV2AccountScope(account) else { return }
                NotificationCenter.default.post(name: .presentWorkHistory, object: session)
            }
        }
        .disabled(!canOpen(work) || appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
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
        Button("作品を削除…", systemImage: "trash", role: .destructive) {
            deletionAccountScope = appState.snapshotSyncV2AccountScopeToken
            pendingDeletion = work
        }
        .disabled(deletingIDs.contains(work.id) || work.availability == .parked || work.availability == .excluded)
    }

    private func open(_ work: StartupLibraryWork) {
        guard canOpen(work) else { return }
        if let importing = appState.libraryPrefetchWorkID ?? appState.snapshotSyncV2RemoteOnlyOpeningWorkID,
           importing != work.workID {
            pendingImportOpen = work
            return
        }
        performOpen(work)
    }

    @ViewBuilder private func takeButton(_ work: StartupLibraryWork) -> some View {
        if work.availability == .remoteOnly {
            Button("この端末に取り込む", systemImage: "arrow.down.circle") {
                appState.takeOntoDevice(workID: work.workID, title: work.title)
            }
            .disabled(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
            .help(appState.libraryPrefetchWorkID != nil || appState.snapshotSyncV2RemoteOnlyOpeningWorkID != nil
                ? SyncV2LibraryPresentation.importBusyReason : "開かずにこの端末へ保存します")
        }
    }

    private func performOpen(_ work: StartupLibraryWork) {
        Task { await appState.openLibraryWork(work) }
    }

    private var filteredWorks: [StartupLibraryWork] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? works : works.filter { $0.title.localizedStandardContains(query) }
    }
}

private extension LibraryPane {
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
        case .unavailable: LibraryText.loadFailed
        }
    }

    private func status(for work: StartupLibraryWork) -> SyncV2LibraryStatus {
        if appState.snapshotSyncPendingDeletionWorkIDs.contains(work.workID) {
            return .init(text: LibraryText.pendingDeletion, symbol: "clock", tone: .secondary)
        }
        return work.status
    }

    private func rowHint(_ work: StartupLibraryWork) -> String {
        if appState.snapshotSyncV2RemoteOnlyOpeningWorkID == work.workID {
            return LibraryImportProgress.hint(SyncV2LibraryPresentation.longImportNotice)
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

struct SnapshotHistorySheet: View {
    @Environment(AppState.self) private var appState
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("\(appState.document.title)の履歴")
                    .font(.title2.weight(.semibold))
                if appState.snapshotSyncHistory.isEmpty {
                    ContentUnavailableView(
                        "履歴はありません",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("この端末の履歴とオンライン履歴を、利用できる範囲で表示します。")
                    )
                } else {
                    List {
                        SnapshotHistorySections(items: appState.snapshotSyncHistory, application: appState.snapshotSyncV2Application, workID: appState.currentSnapshotSyncV2WorkID) { entry in
                            if let application = appState.snapshotSyncV2Application,
                               let workID = appState.currentSnapshotSyncV2WorkID {
                                let session = appState.documentSessionToken
                                let scope = appState.snapshotSyncV2AccountScopeToken
                                let newest = entry.occurrenceID == appState.snapshotSyncHistory.first?.occurrenceID
                                HistoryFetchControls(
                                    application: application, workID: workID, snapshotID: entry.snapshotID,
                                    rowDate: entry.createdAt,
                                    rowKind: HistoryPresentation().subtitle(entry),
                                    historyItem: entry, userDefaults: appState.userDefaults,
                                    announcesStatus: newest
                                ) {
                                    guard appState.documentSessionToken == session,
                                          appState.matchesSnapshotSyncV2AccountScope(scope) else { return }
                                    if await appState.restoreSnapshotV2(snapshotID: entry.snapshotID) {
                                        dismiss()
                                    }
                                }
                                .surfaceCard()
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            } else {
                                SnapshotHistoryLabel(item: entry, userDefaults: appState.userDefaults)
                                    .surfaceCard()
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .padding(Spacing.large)
            .background(FuminiwaColor.paper.color)
            .frame(minWidth: 460, minHeight: 300)
            .accessibilityIdentifier("snapshotSyncV2.historySheet")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる", action: dismiss) } }
        }
        .onChange(of: appState.documentSessionToken) { _, _ in dismiss() }
        .onChange(of: appState.snapshotSyncV2AccountScopeToken) { _, _ in dismiss() }
    }
}
