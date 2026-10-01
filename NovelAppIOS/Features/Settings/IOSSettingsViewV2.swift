import NovelUI
import SwiftUI

struct IOSSettingsView: View {
    let store: IOSDocumentStore
    let userDefaults: UserDefaults
    private let appearanceSections: IOSAppearanceSettingsSections

    init(store: IOSDocumentStore, userDefaults: UserDefaults) {
        self.store = store
        self.userDefaults = userDefaults
        appearanceSections = IOSAppearanceSettingsSections(userDefaults: userDefaults)
    }

    var body: some View {
        List {
            appearanceSections
            Section {
                NavigationLink("APIキー・モデル・プロンプト") {
                    AssistantSettingsView(defaults: userDefaults)
                }
            } header: {
                Label("AI支援", systemImage: "sparkles")
            }
            Section {
                Text(store.authUIState.label).foregroundStyle(.secondary)
                switch store.authUIState {
                case .signedOut, .failed:
                    Button("Appleでサインイン") { Task { await store.signInWithApple() } }
                    Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
                case .signedIn:
                    Button("サインアウト") { Task { await store.signOutFromFuminiwa() } }
                case .signingIn:
                    ProgressView("サインイン中…")
                case .unavailable:
                    Text("同期サーバーが未設定です。端末内で利用できます。")
                }
                Button("同期を再開") { Task { _ = await store.synchronizeSnapshotSyncV2() } }
                    .disabled(!store.canExplicitlySyncCurrentWork)
                if store.isCurrentWorkParked {
                    Text("別アカウントのため保留中。作品の本文と端末履歴は引き続き利用できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("同期", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .navigationTitle("設定")
    }
}
