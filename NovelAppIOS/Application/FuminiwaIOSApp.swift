import Foundation
import NovelSyncV2Application
import NovelSyncV2Runtime
import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store: IOSDocumentStore
    @AppStorage private var appearanceRawValue: String
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if FUMINIWA_TEST_COMPOSITION
        let configuration: TestRuntimeConfiguration
        do {
            configuration = try TestRuntimeConfiguration()
        } catch {
            preconditionFailure("Unable to create the isolated iOS test runtime: \(error)")
        }
        guard let defaults = UserDefaults(suiteName: configuration.defaults.suiteName) else {
            preconditionFailure("Unable to create the isolated iOS test defaults")
        }
        let store = IOSDocumentStore(
            userDefaults: defaults,
            libraryRoot: configuration.localRoot.url,
            runtimeComposition: .test(configuration)
        )
        #else
        let privateWorkingCopyLocation = try? IOSPrivateWorkingCopyLocation.prepareDefault()
        let defaults = UserDefaults.standard
        let store = IOSDocumentStore(
            userDefaults: defaults,
            privateWorkingCopyLocation: privateWorkingCopyLocation
        )
        if privateWorkingCopyLocation == nil {
            store.failStartupForDeviceSyncSafety()
        }
        #endif
        _appearanceRawValue = AppStorage(
            wrappedValue: IOSAppearance.initialRawValue,
            IOSAppearance.preferenceKey,
            store: defaults
        )
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(store: store)
                .defaultAppStorage(store.userDefaults)
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
