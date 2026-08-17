import Foundation
import NovelAuth
import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store: IOSDocumentStore
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation?
        if FuminiwaRuntimeEnvironment.isTestProcess() {
            let testRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "FUMINIWA-iOS-TestHost-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            privateWorkingCopyLocation = try? IOSPrivateWorkingCopyLocation
                .prepareInjectedLibraryRoot(testRoot)
        } else {
            privateWorkingCopyLocation = try? IOSPrivateWorkingCopyLocation.prepareDefault()
        }
        let store = IOSDocumentStore(
            userDefaults: FuminiwaRuntimeEnvironment.applicationUserDefaults(),
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
