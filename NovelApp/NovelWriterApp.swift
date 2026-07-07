import SwiftUI

/// アプリのエントリポイント(docs/DESIGN.md 5.3)。
///
/// v1 では `DocumentGroup` は使わず、単一ウィンドウ + 明示的な Repository 構成とする
/// (D-010)。起動時の読み込み・新規作成は `AppState.bootstrap()` に委譲し、
/// ウィンドウ表示をブロックしないよう `.task` で非同期に行う。
@main
struct NovelWriterApp: App {
    @State private var appState: AppState

    init() {
        _appState = State(initialValue: AppState(dependencies: AppDependencies()))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    await appState.bootstrap()
                }
        }
    }
}
