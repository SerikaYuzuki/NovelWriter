import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

struct IOSLibraryView: View {
    let store: IOSDocumentStore
    let openWork: (WorkID) -> Void
    let makeNewDocument: () -> Void
    var observesLibrary = true

    @AppStorage("library.display") private var display = ShelfDisplay.grid
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var usesGrid: Bool {
        display == .grid && !dynamicTypeSize.isAccessibilitySize
    }

    @State private var searchText = ""
    @State private var pendingImportOpen: WorkID?
    @State private var pendingRename: SyncV2LibraryItem?
    @State private var renameSession: IOSDocumentSessionToken?
    @State private var renameAccountScope: IOSSnapshotSyncV2AccountScope?
    @State private var renameTitle = ""
    @State private var renamingIDs: Set<WorkID> = []
    @State private var renameFailed = false

    @State private var pendingDeletion: SyncV2LibraryItem?
    @State private var deletionSession: IOSDocumentSessionToken?
    @State private var deletionAccountScope: IOSSnapshotSyncV2AccountScope?

    @State private var showingProtection = false

    var body: some View {
        shelfWithOpenFailure
            .sheet(isPresented: $showingProtection) {
                if let application = store.snapshotSyncV2Application {
                    ProtectedWorksView(application: application,
                                       contextID: String(describing: store.snapshotSyncV2AccountScope)) {
                        _ = await store.refreshLibrary()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ShelfDisplayPicker(selection: $display) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新規作品", systemImage: "plus", action: makeNewDocument)
                        Button("作品を取り込む…", systemImage: "square.and.arrow.down") { store.isImporterPresented = true }
                        Button("復元", systemImage: "archivebox") { showingProtection = true }
                    } label: { Label("作品の操作", systemImage: "plus") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FuminiwaColor.paper.color)
            .navigationTitle("作品一覧")
            .alert("作品を完全に削除しますか？", isPresented: Binding(
                get: { pendingDeletion != nil }, set: {
                    if !$0 {
                        pendingDeletion = nil
                    }
                }
            )) {
                Button("削除", role: .destructive) {
                    guard let item = pendingDeletion, let scope = deletionAccountScope else { return }
                    let session = deletionSession
                    Task { _ = await store.deleteLibraryWork(item, expectedSession: session, accountScope: scope) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("「\(pendingDeletion?.title ?? "")」を一覧から削除します。同期した作品のサーバー受領済みデータは1年間保管されます。この端末だけの作品は元に戻せません。")
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
                    guard let item = pendingRename, let scope = renameAccountScope else { return }
                    let session = renameSession
                    let title = renameTitle
                    renamingIDs.insert(item.workID)
                    Task {
                        renameFailed = await !(store.renameLibraryWork(
                            item, title: title, expectedSession: session, accountScope: scope
                        ))
                        renamingIDs.remove(item.workID)
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
        #if FUMINIWA_TEST_COMPOSITION
            .task {
                if ProcessInfo.processInfo.arguments.contains("--library-preview=import-cancel") {
                    pendingImportOpen = store.syncV2LibraryItems.last?.workID
                }
            }
        #endif
            .task(id: store.snapshotSyncV2AccountScope) {
                guard observesLibrary, let application = store.snapshotSyncV2Application else { return }
                for await _ in await application.stateChanges() {
                    guard !Task.isCancelled else { return }
                    _ = try? await store.reloadLibraryItems()
                }
            }
            .task(id: store.snapshotSyncV2AccountScope) {
                if observesLibrary {
                    await store.observeLibraryImports()
                }
            }
            .confirmationDialog("取り込みを中止して開きますか？", isPresented: Binding(
                get: { pendingImportOpen != nil }, set: {
                    if !$0 {
                        pendingImportOpen = nil
                    }
                }
            ), titleVisibility: .visible) {
                if let id = pendingImportOpen {
                    Button("取り込みを中止して開く") {
                        pendingImportOpen = nil
                        Task { await store.cancelLibraryImport(); openWork(id) }
                    }
                }
                Button("キャンセル", role: .cancel) { pendingImportOpen = nil }
            }
            .searchable(text: $searchText, prompt: "作品を検索")
            .refreshable {
                _ = await store.refreshLibrary()
            }
            .task {
                if observesLibrary {
                    _ = await store.refreshLibrary()
                }
            }
    }

    private var shelfWithOpenFailure: some View {
        VStack(spacing: Spacing.small) {
            if let failure = store.snapshotSyncV2RemoteOnlyOpenFailure {
                StatusLabel(remoteOnlyOpenErrorMessage(failure), systemImage: "exclamationmark.circle", tone: .danger)
                    .font(FuminiwaType.rowSecondary)
                    .accessibilityIdentifier("library.openFailure")
            }
            shelfContent
        }
    }

    @ViewBuilder private var shelfContent: some View {
        if usesGrid {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    shelfHeader("作品")
                    libraryNotices
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .top)], alignment: .leading, spacing: Spacing.outer) {
                        workRows
                    }
                    loadMoreButton
                    shelfHeader("アカウント")
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        accountRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.medium)
                    .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card))
                }
                .padding(Spacing.outer)
            }
        } else {
            List {
                Section("作品") {
                    libraryNotices
                    workRows
                    loadMoreButton
                }
                Section("アカウント") {
                    accountRows
                }
            }
        }
    }

    private func shelfHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.medium)
    }

    @ViewBuilder private var libraryNotices: some View {
        if let failure = store.syncV2RemoteCatalogError ?? store.libraryFailure {
            StatusLabel(SyncV2LibraryPresentation.isOffline(failure)
                ? SyncV2LibraryPresentation.offlineNotice : remoteOnlyOpenErrorMessage(failure),
                systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                tone: SyncV2LibraryPresentation.isOffline(failure) ? .offline : .danger)
                .font(FuminiwaType.rowSecondary)
        }
        if store.syncV2LibraryItems.isEmpty {
            if store.libraryIsLoading || store.syncV2RemoteCatalogIsLoading {
                ContentUnavailableView("作品一覧を読み込み中…", systemImage: "arrow.clockwise")
            } else if let failure = store.syncV2RemoteCatalogError ?? store.libraryFailure {
                ContentUnavailableView(SyncV2LibraryPresentation.isOffline(failure) ? "オフラインです" : "作品一覧を読み込めませんでした",
                                       systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                                       description: Text("下に引いて再読み込みできます。「新規作品」から端末内で書き始められます。"))
            } else {
                ContentUnavailableView("最初の作品を書きましょう", systemImage: "book.closed",
                                       description: Text("「新規作品」から、サインインせずに書き始められます。"))
            }
        }
        if !searchText.isEmpty, !store.syncV2LibraryItems.contains(where: { $0.title.localizedStandardContains(searchText) }) {
            Text("作品が見つかりません。検索する言葉を変えてください。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var loadMoreButton: some View {
        if store.syncV2RemoteCatalogCursor != nil {
            Button("サーバーの作品をさらに読み込む") {
                Task { _ = await store.loadMoreRemoteCatalog() }
            }
            .disabled(store.syncV2RemoteCatalogIsLoading)
        }
    }

    @ViewBuilder private var accountRows: some View {
        if store.authUIState == .signedOut {
            Button("Appleでサインイン") {
                Task { await store.signInWithApple() }
            }
            Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
        } else if case .signedIn = store.authUIState {
            Label("サインイン済み", systemImage: "person.crop.circle.badge.checkmark")
            Button("サインアウト") { Task { await store.signOutFromFuminiwa() } }
        } else if store.authUIState == .signingIn {
            ProgressView("サインイン中…")
        } else if store.authUIState == .unavailable {
            Label("アカウント同期は未設定", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else if case .failed = store.authUIState {
            Button("Appleで再試行") {
                Task { await store.signInWithApple() }
            }
            Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
        }
    }

    private var workRows: some View {
        ForEach(store.syncV2LibraryItems.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }, id: \.workID) { item in
            VStack(alignment: .leading, spacing: Spacing.small) {
                IOSLibraryImportRow(store: store, item: item, isRenaming: renamingIDs.contains(item.workID),
                                    open: { requestOpen(item.workID) }, rename: {
                                        renameTitle = item.title
                                        renameSession = store.currentDocumentSessionToken
                                        renameAccountScope = store.snapshotSyncV2AccountScope
                                        pendingRename = item
                                    }, isGrid: usesGrid, delete: { requestDeletion(item) })
                if case .signedIn = store.authUIState, item.accountState == .unbound,
                   item.workID == store.syncV2ActiveWorkID {
                    Button("この作品をこのアカウントへ追加して同期") {
                        Task { _ = await store.cloneActiveWorkIntoSignedInAccount() }
                    }
                    .disabled(store.syncV2AccountCloneInFlight)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !usesGrid {
                    Button("作品を削除…", systemImage: "trash", role: .destructive) { requestDeletion(item) }
                        .disabled(renamingIDs.contains(item.workID) || store.libraryDeletionDisabledReason(for: item.workID) != nil)
                        .accessibilityLabel("「\(item.title)」を削除")
                        .accessibilityHint(store.libraryDeletionDisabledReason(for: item.workID) ?? "確認画面を表示します")
                }
            }
        }
    }

    private func requestDeletion(_ item: SyncV2LibraryItem) {
        guard store.libraryDeletionDisabledReason(for: item.workID) == nil else { return }
        deletionSession = store.currentDocumentSessionToken
        deletionAccountScope = store.snapshotSyncV2AccountScope
        pendingDeletion = item
    }

    private func requestOpen(_ id: WorkID) {
        if let importing = store.libraryPrefetchWorkID ?? store.snapshotSyncV2RemoteOnlyOpeningWorkID,
           importing != id {
            pendingImportOpen = id
        } else {
            openWork(id)
        }
    }
}
