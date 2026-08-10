import Foundation
import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store: IOSDocumentStore
    #if canImport(NovelSyncCloudKit)
    @State private var deviceSyncComposition: IOSDeviceSyncProductionComposition?
    @State private var deviceSyncPreparationFailed: Bool
    #endif
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(NovelSyncCloudKit)
        // iOS SDKはSecTaskによるentitlement読出しを公開していない。
        // unsigned XCTest hostではCloudKit containerを生成せず、安全停止したStoreだけを使う。
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let composition = isRunningTests ? nil : try? IOSDeviceSyncProductionComposition()
        let store = IOSDocumentStore(deviceSyncRuntime: composition?.runtime)
        if composition == nil {
            store.failStartupForDeviceSyncSafety()
        }
        _deviceSyncComposition = State(initialValue: composition)
        _deviceSyncPreparationFailed = State(initialValue: composition == nil)
        _store = State(initialValue: store)
        #else
        _store = State(initialValue: IOSDocumentStore())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(store: store)
                .tint(IOSPalette.accent)
                .preferredColorScheme(
                    IOSAppearance(storedRawValue: appearanceRawValue).colorScheme
                )
                .task {
                    #if canImport(NovelSyncCloudKit)
                    guard !deviceSyncPreparationFailed, let deviceSyncComposition else {
                        store.failStartupForDeviceSyncSafety()
                        return
                    }
                    let deviceSyncBootstrap = Task {
                        await deviceSyncComposition.bootstrap()
                    }
                    #endif
                    await store.bootstrap()
                    #if canImport(NovelSyncCloudKit)
                    await deviceSyncBootstrap.value
                    await store.refreshOrPrepareSelectedEpisodeDeviceSync()
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        if newPhase == .active {
                            await store.refreshOrPrepareSelectedEpisodeDeviceSync()
                        } else {
                            await store.flushDeviceSyncWithBackgroundTime()
                        }
                    }
                }
        }
    }
}
