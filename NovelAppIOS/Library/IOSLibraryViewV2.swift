import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import NovelWorkspaceUI
import SwiftUI

struct IOSLibraryView: View {
    @Environment(WorkspaceModel.self) private var workspace
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
    @State private var renameSession: WorkspaceSessionToken?
    @State private var renameAccountScope: WorkspaceAccountScope?
    @State private var renameTitle = ""
    @State private var renamingIDs: Set<WorkID> = []
    @State private var renameFailed = false

    @State private var pendingDeletion: SyncV2LibraryItem?
    @State private var deletionSession: WorkspaceSessionToken?
    @State private var deletionAccountScope: WorkspaceAccountScope?

    @State private var showingProtection = false

    var body: some View {
        shelfWithOpenFailure
            .sheet(isPresented: $showingProtection) {
                if let application = store.snapshotSyncV2Application {
                    ProtectedWorksView(application: application,
                                       contextID: String(describing: store.snapshotSyncV2AccountScope),
                                       localCopies: workspace.trashLocalItems,
                                       removedCopyIDs: workspace.removedTrashCopyIDs,
                                       recoverServer: { await store.restoreTrashWork($0, request: $1) },
                                       rescueLocal: { await store.rescueTrashWork($0) },
                                       deleteLocal: { await store.deleteTrashWork($0) }) {
                        _ = await store.refreshFullLibrary()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ShelfDisplayPicker(selection: $display) }
                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("作品一覧を更新", systemImage: "arrow.clockwise") { Task { _ = await store.refreshFullLibrary() } }
                            .disabled(workspace.libraryFullRefreshIsLoading)
                        Button("新規作品", systemImage: "plus", action: makeNewDocument)
                        Button(LibraryText.importWork, systemImage: "square.and.arrow.down") { store.isImporterPresented = true }
                        Button("ゴミ箱", systemImage: "archivebox") { showingProtection = true }
                    } label: { Label("作品の操作", systemImage: "plus") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FuminiwaColor.paper.color)
            .navigationTitle("作品一覧")
            .alert(LibraryText.deleteConfirmation, isPresented: Binding(
                get: { pendingDeletion != nil }, set: {
                    if !$0 {
                        pendingDeletion = nil
                    }
                }
            )) {
                Button(LibraryText.delete, role: .destructive) {
                    guard let item = pendingDeletion, let scope = deletionAccountScope else { return }
                    let session = deletionSession
                    Task { _ = await store.deleteLibraryWork(item, expectedSession: session, accountScope: scope) }
                }
                Button(LibraryText.cancel, role: .cancel) {}
            } message: {
                Text(LibraryText.deletionMessage(title: pendingDeletion?.title ?? ""))
            }
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
                Button(LibraryText.cancel, role: .cancel) {}
            }
            .alert(LibraryText.renameFailed, isPresented: $renameFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(LibraryText.renameRetry)
            }
        #if FUMINIWA_TEST_COMPOSITION
            .task {
                if ProcessInfo.processInfo.arguments.contains("--library-preview=import-cancel") {
                    pendingImportOpen = workspace.libraryRows.last?.workID
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
            .confirmationDialog(LibraryText.cancelImportConfirmation, isPresented: Binding(
                get: { pendingImportOpen != nil }, set: {
                    if !$0 {
                        pendingImportOpen = nil
                    }
                }
            ), titleVisibility: .visible) {
                if let id = pendingImportOpen {
                    Button(LibraryText.cancelImportAndOpen) {
                        pendingImportOpen = nil
                        Task { await store.cancelLibraryImport(); openWork(id) }
                    }
                }
                Button(LibraryText.cancel, role: .cancel) { pendingImportOpen = nil }
            }
            .searchable(text: $searchText, prompt: LibraryText.search)
            .refreshable {
                _ = await store.refreshFullLibrary()
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
        if workspace.libraryFullRefreshIsLoading {
            ProgressView("作品一覧を更新中…")
        }
        if let notice = workspace.libraryRefreshNotice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
        if let failure = store.syncV2RemoteCatalogError ?? workspace.libraryFailure {
            StatusLabel(SyncV2LibraryPresentation.isOffline(failure)
                ? SyncV2LibraryPresentation.offlineNotice : remoteOnlyOpenErrorMessage(failure),
                systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                tone: SyncV2LibraryPresentation.isOffline(failure) ? .offline : .danger)
                .font(FuminiwaType.rowSecondary)
        }
        if workspace.libraryRows.isEmpty {
            if workspace.libraryIsLoading || store.syncV2RemoteCatalogIsLoading {
                ContentUnavailableView(LibraryText.loading, systemImage: "arrow.clockwise")
            } else if let failure = store.syncV2RemoteCatalogError ?? workspace.libraryFailure {
                ContentUnavailableView(SyncV2LibraryPresentation.isOffline(failure) ? LibraryText.offline : LibraryText.loadFailed,
                                       systemImage: SyncV2LibraryPresentation.isOffline(failure) ? "wifi.slash" : "exclamationmark.circle",
                                       description: Text(LibraryText.retryIOS))
            } else {
                ContentUnavailableView(LibraryText.empty, systemImage: "book.closed",
                                       description: Text(LibraryText.emptyIOS))
            }
        }
        if !searchText.isEmpty, !workspace.libraryRows.contains(where: { $0.title.localizedStandardContains(searchText) }) {
            Text(LibraryText.noSearchResultsNotice)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var loadMoreButton: some View {
        if workspace.remoteCatalogCursor != nil {
            Button(LibraryText.loadMore) {
                Task { _ = await store.loadMoreRemoteCatalog() }
            }
            .disabled(store.syncV2RemoteCatalogIsLoading)
        }
    }

    @ViewBuilder private var accountRows: some View {
        if workspace.authUIState == .signedOut {
            Button("Appleでサインイン") {
                Task { await store.signInWithApple() }
            }
            Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
        } else if case .signedIn = workspace.authUIState {
            Label("サインイン済み", systemImage: "person.crop.circle.badge.checkmark")
            Button("サインアウト") { Task { await store.signOutFromFuminiwa() } }
        } else if workspace.authUIState == .signingIn {
            ProgressView("サインイン中…")
        } else if workspace.authUIState == .unavailable {
            Label("アカウント同期は未設定", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else if case .failed = workspace.authUIState {
            Button("Appleで再試行") {
                Task { await store.signInWithApple() }
            }
            Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
        }
    }

    private var workRows: some View {
        ForEach(workspace.libraryRows.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }, id: \.workID) { item in
            VStack(alignment: .leading, spacing: Spacing.small) {
                IOSLibraryImportRow(store: store, item: item, isRenaming: renamingIDs.contains(item.workID),
                                    open: { requestOpen(item.workID) }, rename: {
                                        renameTitle = item.title
                                        renameSession = store.currentDocumentSessionToken
                                        renameAccountScope = store.snapshotSyncV2AccountScope
                                        pendingRename = item
                                    }, isGrid: usesGrid, delete: { requestDeletion(item) })
                if case .signedIn = workspace.authUIState, item.accountState == .unbound,
                   item.workID == workspace.activeWorkID {
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
