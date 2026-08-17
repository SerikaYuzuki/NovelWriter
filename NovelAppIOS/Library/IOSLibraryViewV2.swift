import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

struct IOSLibraryView: View {
    let store: IOSDocumentStore
    let openWork: (WorkID) -> Void
    let makeNewDocument: () -> Void

    var body: some View {
        List {
            Section("作品") {
                if store.authUIState == .signedOut {
                    Button("Appleでサインイン") {
                        Task { await store.signInWithApple() }
                    }
                } else if store.authUIState == .unavailable {
                    Label("アカウント同期は未設定", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if case .failed = store.authUIState {
                    Button("Appleで再試行") {
                        Task { await store.signInWithApple() }
                    }
                }
                if store.syncV2LibraryItems.isEmpty {
                    Text(store.authUIState == .signedOut
                        ? "サインインするとサーバーの作品を表示します"
                        : "端末内に保存された作品はありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.syncV2LibraryItems, id: \.workID) { item in
                    Button {
                        openWork(item.workID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title.isEmpty ? "名称未設定の作品" : item.title)
                            HStack(spacing: 6) {
                                Text(item.availability.japaneseLabel)
                                Text(item.remoteProgress.japaneseLabel)
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
        .navigationTitle("作品棚")
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
