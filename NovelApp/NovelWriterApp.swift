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
///
/// - Note: `documentPanelPresenter`(File メニューのパネル結線、4.5-2b)は
///   `appState` を初期化時に参照する必要があるため、上記の delegate とは異なり
///   `init` 内で `appState` と対にして生成する。これは安全: `@State` は同じ
///   view identity 内で複数回 `init` が呼ばれても最初の一回の初期値しか採用しない
///   ため、`appState` と `documentPanelPresenter` は常に同じ回の `init` 呼び出し
///   由来のペアとして採用されるか、両方まとめて捨てられるかのどちらかになり、
///   ペアが食い違うことはない(delegate のような `@State` 外の `weak` 参照とは
///   性質が異なる)。
@main
struct NovelWriterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var appState: AppState
    @State private var editorSettings = EditorSettings()
    @State private var documentPanelPresenter: DocumentPanelPresenter

    init() {
        let appState = AppState(dependencies: AppDependencies())
        _appState = State(initialValue: appState)
        _documentPanelPresenter = State(initialValue: DocumentPanelPresenter(appState: appState))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(editorSettings)
                .environment(documentPanelPresenter)
                .task {
                    applicationDelegate.appState = appState
                    await appState.bootstrap()
                }
        }
        .commands {
            // 新規作品はこのアプリの作品ライフサイクルの入口であり、`WindowGroup`
            // 既定の「新規ウインドウ」(単一ウィンドウ方針 D-010 と衝突する)を
            // 置き換える。
            CommandGroup(replacing: .newItem) {
                Button("新規") {
                    documentPanelPresenter.presentNewDocument()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("開く…") {
                    documentPanelPresenter.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Cmd+Shift+S は macOS の「別名で保存…」の慣習を優先する
            // (docs/DECISIONS.md D-025)。スナップショット保存は Cmd+Option+S へ移す。
            CommandGroup(after: .saveItem) {
                Button("別名で保存…") {
                    documentPanelPresenter.presentSaveAsPanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Finder で表示") {
                    documentPanelPresenter.revealInFinder()
                }

                Divider()

                Button("スナップショットを保存") {
                    Task { await appState.createSnapshot() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            CommandMenu("表示") {
                ForEach(ProjectSection.allCases) { section in
                    Button {
                        appState.selectProjectSection(section)
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .keyboardShortcut(section.keyboardShortcut, modifiers: .command)
                }
            }

            SidebarCommands()
        }

        Settings {
            EditorSettingsView()
                .environment(editorSettings)
        }
    }
}
