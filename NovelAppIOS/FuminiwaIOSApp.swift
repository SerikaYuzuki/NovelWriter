import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store = IOSDocumentStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSRootView(store: store)
                .task {
                    await store.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase != .active else { return }
                    Task {
                        await store.saveNow()
                    }
                }
                .onOpenURL { url in
                    Task {
                        await store.handleExternalPackageURL(url)
                    }
                }
        }
    }
}
