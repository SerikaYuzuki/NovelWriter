import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

struct IOSLibraryView: View {
    let store: IOSDocumentStore
    let openWork: (WorkID) -> Void
    let makeNewDocument: () -> Void

    @State private var searchText = ""
    @State private var pendingRename: SyncV2LibraryItem?
    @State private var renameSession: IOSDocumentSessionToken?
    @State private var renameAccountScope: IOSSnapshotSyncV2AccountScope?
    @State private var renameTitle = ""
    @State private var renamingIDs: Set<WorkID> = []
    @State private var renameFailed = false

    @State private var showingProtection = false

    var body: some View {
        List {
            Section("作品") {
                if store.authUIState == .signedOut {
                    Button("Appleでサインイン") {
                        Task { await store.signInWithApple() }
                    }
                    Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
                } else if store.authUIState == .unavailable {
                    Label("アカウント同期は未設定", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if case .failed = store.authUIState {
                    Button("Appleで再試行") {
                        Task { await store.signInWithApple() }
                    }
                    Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
                }
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
                ForEach(store.syncV2LibraryItems.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }, id: \.workID) { item in
                    Button {
                        openWork(item.workID)
                    } label: {
                        HStack(spacing: Spacing.small) {
                            // Leading slot reserved for a future cover thumbnail.
                            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                                Text(item.title.isEmpty ? "名称未設定の作品" : item.title)
                                    .foregroundStyle(FuminiwaColor.textPrimary.color)
                                if store.snapshotSyncV2RemoteOnlyOpeningWorkID == item.workID,
                                   let startedAt = store.snapshotSyncV2RemoteOnlyOpenStartedAt {
                                    LibraryImportProgress(startedAt: startedAt,
                                                          longImportNotice: SyncV2LibraryPresentation.longImportNotice)
                                } else if renamingIDs.contains(item.workID) {
                                    ProgressView("作品名を変更中…")
                                } else {
                                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                                        StatusLabel(item.status.text, systemImage: item.status.symbol,
                                                    tone: StatusTone(rawValue: item.status.tone.rawValue) ?? .secondary)
                                            .font(FuminiwaType.rowSecondary)
                                    }
                                }
                            }
                            Spacer()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(renamingIDs.contains(item.workID) ? "作品名を変更中です" :
                        item.workID == store.snapshotSyncV2RemoteOnlyOpeningWorkID ? "この作品を取り込み中です" :
                        item.availability != .remoteOnly ? "" : store.snapshotSyncV2RemoteOnlyOpeningWorkID == nil
                        ? SyncV2LibraryPresentation.remoteOnlyHint : SyncV2LibraryPresentation.importBusyReason)
                    .disabled(renamingIDs.contains(item.workID) ||
                        (item.availability == .remoteOnly && store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil))
                    .contextMenu {
                        Button("作品名を変更", systemImage: "pencil") {
                            renameTitle = item.title
                            renameSession = store.currentDocumentSessionToken
                            renameAccountScope = store.snapshotSyncV2AccountScope
                            pendingRename = item
                        }
                        .disabled(renamingIDs.contains(item.workID))
                    }
                    if item.accountState == .unbound,
                       item.workID == store.syncV2ActiveWorkID {
                        Button("この作品をこのアカウントへ追加して同期") {
                            Task { _ = await store.cloneActiveWorkIntoSignedInAccount() }
                        }
                        .disabled(store.syncV2AccountCloneInFlight)
                    }
                }
                if store.syncV2RemoteCatalogCursor != nil {
                    Button("サーバーの作品をさらに読み込む") {
                        Task { _ = await store.loadMoreRemoteCatalog() }
                    }
                    .disabled(store.syncV2RemoteCatalogIsLoading)
                }
            }
            Section {
                Button("新規作品", action: makeNewDocument)
                Button("作品を取り込む…") { store.isImporterPresented = true }
            }
        }
        .sheet(isPresented: $showingProtection) {
            if let application = store.snapshotSyncV2Application {
                ProtectedWorksView(application: application,
                                   contextID: String(describing: store.snapshotSyncV2AccountScope)) {
                    _ = await store.refreshLibrary()
                }
            }
        }
        .toolbar { Button("復元", systemImage: "archivebox") { showingProtection = true } }
        .navigationTitle("作品一覧")
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
        .searchable(text: $searchText, prompt: "作品を検索")
        .refreshable {
            _ = await store.refreshLibrary()
        }
        .task { _ = await store.refreshLibrary() }
    }
}
