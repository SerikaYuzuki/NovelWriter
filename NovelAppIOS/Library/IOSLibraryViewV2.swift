import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

struct IOSLibraryView: View {
    let store: IOSDocumentStore
    let openWork: (WorkID) -> Void
    let makeNewDocument: () -> Void

    @State private var delayClock = SyncV2DelayClock()
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
                if store.syncV2LibraryItems.isEmpty {
                    Text(store.authUIState == .signedOut
                        ? "「新規作品」から、サインインせずに書き始められます"
                        : "端末内に保存された作品はありません")
                        .foregroundStyle(.secondary)
                }
                if !searchText.isEmpty, !store.syncV2LibraryItems.contains(where: { $0.title.localizedStandardContains(searchText) }) {
                    Text("作品が見つかりません。検索する言葉を変えてください。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.syncV2LibraryItems.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }, id: \.workID) { item in
                    Button {
                        openWork(item.workID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title.isEmpty ? "名称未設定の作品" : item.title)
                            if renamingIDs.contains(item.workID) {
                                ProgressView("作品名を変更中…")
                            }
                            HStack(spacing: 6) {
                                Text(item.availability.japaneseLabel)
                                TimelineView(.periodic(from: .now, by: 15)) { _ in
                                    Text(SyncV2DelayNotice.label(progress: item.remoteProgress,
                                                                 since: item.oldestUnreceivedAt, now: delayClock.now))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if item.conflict != nil {
                                Text("競合を確認してください")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else if item.availability == .remoteOnly {
                                Text("サーバーからこの端末へ取り込み")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if item.accountState == .unbound {
                                Text("この端末のみ・アカウントへ追加可能")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(renamingIDs.contains(item.workID))
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
                if let error = store.syncV2RemoteCatalogError {
                    Text("サーバー一覧: \(error)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("新規作品", action: makeNewDocument)
                Button(".novelpkg を取り込む") { store.isImporterPresented = true }
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

private extension SyncV2LibraryAvailability {
    var japaneseLabel: String {
        switch self {
        case .localOnly: "端末のみ"
        case .cached: "端末・サーバー"
        case .remoteOnly: "サーバーのみ"
        }
    }
}
