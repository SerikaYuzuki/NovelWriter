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
            IOSDeviceSyncSettingsView(store: store)
        }
        .navigationTitle("設定")
    }
}
