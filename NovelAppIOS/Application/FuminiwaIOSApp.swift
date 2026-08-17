import Foundation
import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store: IOSDocumentStore
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The shipped @main host is always production.  Test roots and fake
        // transports are provided by IOSDocumentStore's explicit injected
        // composition used from the test target; XCTest/environment markers
        // must never redirect this host to a temporary SQLite database.
        let privateWorkingCopyLocation = try? IOSPrivateWorkingCopyLocation.prepareDefault()
        let store = IOSDocumentStore(
            userDefaults: UserDefaults.standard,
            privateWorkingCopyLocation: privateWorkingCopyLocation
        )
        if privateWorkingCopyLocation == nil {
            store.failStartupForDeviceSyncSafety()
        }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(store: store)
                .tint(IOSPalette.accent)
                .preferredColorScheme(
                    IOSAppearance(storedRawValue: appearanceRawValue).colorScheme
                )
                .task {
                    _ = await store.configureSnapshotSyncV2()
                    await store.restoreFuminiwaSession()
                    await store.bootstrap(localFirst: true)
                    await store.resumeSnapshotSyncV2()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        if newPhase == .background {
                            // `.inactive` はアプリスイッチャーや一時的な割り込みでも
                            // 発生する。ここで保存境界を開始すると、スイッチャーの
                            // プレビューをロード表示で覆い、復帰直後の入力も止めてしまう。
                            // 実際に中断される `.background` でだけ端末保存を行う。
                            await store.flushDeviceSyncWithBackgroundTime()
                        } else if newPhase == .active {
                            // Foreground resume is a non-blocking wake of the
                            // durable v2 outbox; no network result gates UI.
                            Task { await store.resumeSnapshotSyncV2() }
                        }
                    }
                }
        }
    }
}
