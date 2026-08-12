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
        let privateWorkingCopyLocation = try? IOSPrivateWorkingCopyLocation.prepareDefault()
        #if canImport(NovelSyncCloudKit)
        // iOS SDKはSecTaskによるentitlement読出しを公開していない。
        // unsigned XCTest hostではCloudKit containerを生成せず、安全停止したStoreだけを使う。
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let composition: IOSDeviceSyncProductionComposition? = if isRunningTests {
            nil
        } else if let privateWorkingCopyLocation {
            try? IOSDeviceSyncProductionComposition(
                privateWorkingCopyLocation: privateWorkingCopyLocation
            )
        } else {
            nil
        }
        let store = IOSDocumentStore(
            deviceSyncRuntime: composition?.runtime,
            privateWorkingCopyLocation: privateWorkingCopyLocation
        )
        if privateWorkingCopyLocation == nil || composition == nil {
            store.failStartupForDeviceSyncSafety()
        }
        _deviceSyncComposition = State(initialValue: composition)
        _deviceSyncPreparationFailed = State(initialValue: composition == nil)
        _store = State(initialValue: store)
        #else
        let store = IOSDocumentStore(privateWorkingCopyLocation: privateWorkingCopyLocation)
        if privateWorkingCopyLocation == nil {
            store.failStartupForDeviceSyncSafety()
        }
        _store = State(initialValue: store)
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
                    // 端末内WALの確認とEditor解放はCloudKit bootstrapを待たせない。
                    await store.refreshOrPrepareSelectedEpisodeDeviceSync()
                    await deviceSyncBootstrap.value
                    // 初回のStore bootstrapはCloudKit account確認を待たずlocal shelfを
                    // 先に出す。runtimeがreadyになった後、remote catalogを必ず再読込する。
                    _ = await store.refreshLibrary()
                    await store.refreshOrPrepareSelectedEpisodeDeviceSync()
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        if newPhase == .active {
                            await store.refreshOrPrepareSelectedEpisodeDeviceSync()
                            await store.retryPendingCloudPublicationsInBackground()
                        } else {
                            await store.flushDeviceSyncWithBackgroundTime()
                        }
                    }
                }
        }
    }
}
