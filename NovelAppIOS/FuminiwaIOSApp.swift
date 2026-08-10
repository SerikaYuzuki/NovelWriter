import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store = IOSDocumentStore()
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSRootView(store: store)
                .tint(IOSPalette.accent)
                .preferredColorScheme(
                    IOSAppearance(storedRawValue: appearanceRawValue).colorScheme
                )
                .task {
                    await store.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase != .active else { return }
                    Task {
                        await store.saveNow()
                    }
                }
        }
    }
}
