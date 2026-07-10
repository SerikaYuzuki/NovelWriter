import AppKit
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
    @State private var snapshotMenuPresenter: SnapshotMenuPresenter
    @State private var editorSearchSession = EditorSearchSession()

    init() {
        let appState = AppState(dependencies: AppDependencies())
        _appState = State(initialValue: appState)
        _documentPanelPresenter = State(initialValue: DocumentPanelPresenter(appState: appState))
        _snapshotMenuPresenter = State(initialValue: SnapshotMenuPresenter(appState: appState))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(editorSettings)
                .environment(documentPanelPresenter)
                .environment(snapshotMenuPresenter)
                .environment(editorSearchSession)
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
                    Task {
                        _ = await appState.createSnapshot()
                        await snapshotMenuPresenter.refresh()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                SnapshotRestoreCommands(presenter: snapshotMenuPresenter)
            }

            CommandMenu("章") {
                Button("章を追加") {
                    appState.addChapter()
                }

                Button("章メモ") {
                    NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
                }
                .disabled(appState.selectedChapter == nil)

                Divider()

                Menu("この章") {
                    ChapterContextMenuContent(
                        appState: appState,
                        onOpenCharacter: { characterID in
                            appState.selectCharacter(characterID)
                            appState.selectProjectSection(.characters)
                        },
                        onOpenPlotCard: { cardID in
                            appState.selectPlotCard(cardID)
                            appState.selectProjectSection(.plot)
                        }
                    )
                }
                .disabled(appState.selectedChapter == nil)
            }

            CommandGroup(after: .textEditing) {
                Divider()
                WorkbenchFindCommands(
                    appState: appState,
                    editorSearchSession: editorSearchSession
                )
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

                Divider()

                Button("AI Assistant") {
                    appState.aiAssistantPanel.isExpanded.toggle()
                }
                .keyboardShortcut("j", modifiers: .command)
            }

            SidebarCommands()
            ToolbarCommands()
        }

        Settings {
            EditorSettingsView()
                .environment(editorSettings)
        }
    }
}

private struct SnapshotRestoreCommands: View {
    @Bindable var presenter: SnapshotMenuPresenter

    var body: some View {
        Menu("スナップショットを復元") {
            if presenter.snapshots.isEmpty {
                Text("スナップショットはありません")
            } else {
                ForEach(presenter.snapshots) { snapshot in
                    Menu(snapshot.displayName) {
                        Button("この状態に戻す…") {
                            presenter.snapshotPendingRestore = snapshot
                        }
                        Button("Finder で表示") {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshot.url])
                        }
                    }
                }
            }
        }
        .task {
            await presenter.refresh()
        }
    }
}

private struct WorkbenchFindCommands: View {
    @FocusedValue(\.workbenchSearchSurface) private var searchSurface

    @Bindable var appState: AppState
    @Bindable var editorSearchSession: EditorSearchSession

    var body: some View {
        Button("検索…") {
            switch searchSurface {
            case .outline:
                appState.outlinePresentation.isSearchVisible = true
                appState.outlinePresentation.pinnedSearchByKeyboard = true
            case .editor, .none:
                guard appState.workspaceSelection.section == .structure else { return }
                editorSearchSession.focusSearchField()
            }
        }
        .keyboardShortcut("f", modifiers: .command)

        Button("次を検索") {
            guard appState.workspaceSelection.section == .structure else { return }
            editorSearchSession.jump(direction: .forward, in: appState.selectedChapter)
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("前を検索") {
            guard appState.workspaceSelection.section == .structure else { return }
            editorSearchSession.jump(direction: .backward, in: appState.selectedChapter)
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}
