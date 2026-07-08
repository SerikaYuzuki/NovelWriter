import SwiftUI

/// アプリのエントリポイント(docs/DESIGN.md 5.3)。
///
/// v1 では `DocumentGroup` は使わず、単一ウィンドウ + 明示的な Repository 構成とする
/// (D-010)。起動時の読み込み・新規作成は `AppState.bootstrap()` に委譲し、
/// ウィンドウ表示をブロックしないよう `.task` で非同期に行う。
///
/// - 重要: `ApplicationDelegate.appState` の配線は、あえて `init` ではなく
///   `WindowGroup` の `.task` の先頭(`bootstrap()` の直前)で行う。SwiftUI は
///   `App` 準拠の構造体を必要に応じて何度でも再生成しうるため、もし `init` 内で
///   配線すると、再生成のたびに `AppState(dependencies:)` で新しく作られた
///   (`@State` には採用されない)使い捨てインスタンスを `weak` な delegate に
///   渡してしまい、即座に解放されて `nil` に戻ってしまう。`.task` 内で
///   `appState`(`@State` プロパティ)を読めば、常に実際に使われている
///   永続的なインスタンスを参照できる。
@main
struct NovelWriterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var appState = AppState(dependencies: AppDependencies())
    @State private var editorSettings = EditorSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(editorSettings)
                .task {
                    applicationDelegate.appState = appState
                    await appState.bootstrap()
                }
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("スナップショットを保存") {
                    Task { await appState.createSnapshot() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("表示") {
                Picker("モード", selection: modeBinding) {
                    ForEach(AppMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button("執筆") {
                    appState.mode = .writing
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("キャラクター") {
                    appState.mode = .characters
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("プロット") {
                    appState.mode = .plot
                }
                .keyboardShortcut("3", modifiers: .command)
            }
        }

        Settings {
            EditorSettingsView()
                .environment(editorSettings)
        }
    }

    private var modeBinding: Binding<AppMode> {
        Binding(
            get: { appState.mode },
            set: { appState.mode = $0 }
        )
    }
}
