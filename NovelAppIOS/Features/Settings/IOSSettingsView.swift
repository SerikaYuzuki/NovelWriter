import SwiftUI

struct IOSSettingsView: View {
    let store: IOSDocumentStore
    private let appearanceSections: IOSAppearanceSettingsSections

    init(store: IOSDocumentStore, userDefaults: UserDefaults = .standard) {
        self.store = store
        appearanceSections = IOSAppearanceSettingsSections(userDefaults: userDefaults)
    }

    var body: some View {
        List {
            appearanceSections
            if store.usesSnapshotSyncRuntime {
                IOSSnapshotSyncSettingsView(store: store)
            } else {
                IOSDeviceSyncSettingsView(store: store)
            }
        }
        .navigationTitle("設定")
    }
}

private struct IOSSnapshotSyncSettingsView: View {
    let store: IOSDocumentStore

    var body: some View {
        Section {
            Label(store.authUIState.label, systemImage: accountIcon)

            switch store.authUIState {
            case .signedOut, .failed:
                Button("Appleでサインイン") {
                    Task { await store.signInWithApple() }
                }
                .accessibilityIdentifier("ios.settings.signInWithApple")
            case .signingIn:
                ProgressView("サインイン中…")
            case .signedIn:
                Button("サインアウト") {
                    Task { await store.signOutFromFuminiwa() }
                }
                .accessibilityIdentifier("ios.settings.signOut")
            case .unavailable:
                Text("認証機能を利用できません。")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await store.saveAndSyncSnapshotNow() }
            } label: {
                Label("今すぐ同期", systemImage: "arrow.clockwise")
            }
            .disabled(!store.canExplicitlySyncCurrentWork)
            .accessibilityIdentifier("ios.settings.syncNow")
        } header: {
            Text("サーバー同期")
        } footer: {
            Text("原稿は先にこの端末へ保存されます。サーバーへの送信は接続が戻ったときに自動で再開します。")
        }
    }

    private var accountIcon: String {
        switch store.authUIState {
        case .signedIn:
            "person.crop.circle.fill"
        case .failed:
            "exclamationmark.triangle"
        default:
            "person.crop.circle"
        }
    }
}
