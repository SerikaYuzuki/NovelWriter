import SwiftUI

struct IOSSettingsView: View {
    let store: IOSDocumentStore

    var body: some View {
        List {
            IOSAppearanceSettingsView()
            IOSDeviceSyncSettingsView(store: store)
        }
        .navigationTitle("設定")
    }
}
