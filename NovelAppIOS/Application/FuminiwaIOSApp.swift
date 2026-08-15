import Foundation
import SwiftUI

@main
struct FuminiwaIOSApp: App {
    @State private var store: IOSDocumentStore
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let privateWorkingCopyLocation = try? IOSPrivateWorkingCopyLocation.prepareDefault()
        let store = IOSDocumentStore(privateWorkingCopyLocation: privateWorkingCopyLocation)
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
                    await store.bootstrap(localFirst: true)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        if newPhase == .background {
                            // `.inactive` はアプリスイッチャーや一時的な割り込みでも
                            // 発生する。ここで保存境界を開始すると、スイッチャーの
                            // プレビューをロード表示で覆い、復帰直後の入力も止めてしまう。
                            // 実際に中断される `.background` でだけ端末保存を行う。
                            await store.flushDeviceSyncWithBackgroundTime()
                        }
                    }
                }
        }
    }
}
