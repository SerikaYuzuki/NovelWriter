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
            Section("同期") {
                Text(store.authUIState.label).foregroundStyle(.secondary)
                if store.authUIState == .signedOut || store.authUIState == .unavailable {
                    Button("Appleでサインイン") { Task { await store.signInWithApple() } }
                } else {
                    Button("サインアウト") { Task { await store.signOutFromFuminiwa() } }
                }
                Button("同期を再開") { Task { _ = await store.synchronizeSnapshotSyncV2() } }
            }
        }
        .navigationTitle("設定")
    }
}
