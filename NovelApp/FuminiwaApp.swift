import AppKit
import EditorKit
import Foundation
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
struct FuminiwaApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var appState: AppState
    @State private var editorSettings: EditorSettings
    @State private var documentPanelPresenter: DocumentPanelPresenter
    @State private var snapshotMenuPresenter: SnapshotMenuPresenter
    @State private var exportPresenter: ExportPresenter
    @State private var editorSearchSession = EditorSearchSession()
    @State private var editorCommandSession: EditorCommandSession
    #if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
    @State private var deviceSyncComposition: DeviceSyncProductionComposition?
    @State private var deviceSyncPreparationFailed: Bool
    #endif
    #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
    @State private var editorAISelectionSession: EditorAISelectionSession
    @State private var aiProofreadingOperation: AIProofreadingOperation
    #endif

    init() {
        let defaults = UserDefaults.standard
        if AppBuildFlavor.migratesLegacyPreferences {
            LegacyPreferenceMigration.migrateIfNeeded(to: defaults)
        }

        let editorCommandSession = EditorCommandSession()
        #if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
        let deviceSyncComposition = try? DeviceSyncProductionComposition()
        let deviceSyncRuntime = deviceSyncComposition?.runtime
        #else
        let deviceSyncRuntime: DeviceSyncRuntime? = nil
        #endif
        let appState = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                defaultDocumentDirectoryName: AppBuildFlavor.defaultDocumentDirectoryName,
                editorCommandSession: editorCommandSession,
                deviceSyncRuntime: deviceSyncRuntime
            )
        )
        #if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
        if deviceSyncComposition == nil {
            appState.failStartupForDeviceSyncSafety()
        }
        #endif
        _appState = State(initialValue: appState)
        _editorSettings = State(initialValue: EditorSettings(userDefaults: defaults))
        _documentPanelPresenter = State(initialValue: DocumentPanelPresenter(appState: appState))
        _snapshotMenuPresenter = State(initialValue: SnapshotMenuPresenter(appState: appState))
        _exportPresenter = State(initialValue: ExportPresenter(appState: appState))
        _editorCommandSession = State(initialValue: editorCommandSession)
        #if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
        _deviceSyncComposition = State(initialValue: deviceSyncComposition)
        _deviceSyncPreparationFailed = State(initialValue: deviceSyncComposition == nil)
        #endif
        #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
        let editorAISelectionSession = EditorAISelectionSession()
        let aiProofreadingOperation = AIProofreadingOperation(
            documentContext: AIProofreadingDocumentContextClient(appState: appState),
            editorSelection: AIEditorSelectionClient(session: editorAISelectionSession),
            route: .developmentFake()
        )
        editorAISelectionSession.setTransactionRevisionChangeHandler { [weak aiProofreadingOperation] in
            aiProofreadingOperation?.refreshApplicability()
        }
        _editorAISelectionSession = State(initialValue: editorAISelectionSession)
        _aiProofreadingOperation = State(initialValue: aiProofreadingOperation)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(editorSettings)
                .environment(documentPanelPresenter)
                .environment(snapshotMenuPresenter)
                .environment(exportPresenter)
                .environment(editorSearchSession)
                .environment(editorCommandSession)
            #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
                .environment(aiProofreadingOperation)
                .environment(\.experimentalAISelectionSession, editorAISelectionSession)
            #endif
                .task {
                    applicationDelegate.attach(appState: appState)
                    #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
                    applicationDelegate.attachTerminationPreparation {
                        await aiProofreadingOperation.shutdown()
                    }
                    #endif
                    let startupOpenURL = applicationDelegate.takeStartupOpenURL()
                    #if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
                    guard !deviceSyncPreparationFailed, let deviceSyncComposition else {
                        appState.failStartupForDeviceSyncSafety()
                        return
                    }
                    let deviceSyncBootstrap = Task {
                        await deviceSyncComposition.bootstrap()
                    }
                    #endif
                    await appState.bootstrap(opening: startupOpenURL)
                    applicationDelegate.finishBootstrap()
                    #if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
                    await deviceSyncBootstrap.value
                    await appState.refreshOrPrepareSelectedEpisodeDeviceSync()
                    #endif
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
                .disabled(!appState.permitsDocumentChoice)

                Button("開く…") {
                    documentPanelPresenter.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!appState.permitsDocumentChoice)
            }

            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    Task { await appState.saveNow() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.permitsDocumentInteraction)
            }

            // Cmd+Shift+S は macOS の「別名で保存…」の慣習を優先する
            // (docs/DECISIONS.md D-025)。スナップショット保存は Cmd+Option+S へ移す。
            CommandGroup(after: .saveItem) {
                Button("別名で保存…") {
                    documentPanelPresenter.presentSaveAsPanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.permitsDocumentInteraction)

                Button("書き出す…") {
                    exportPresenter.present()
                }
                .disabled(!appState.permitsDocumentInteraction || exportPresenter.state.isExporting)

                Button("Finder で表示") {
                    documentPanelPresenter.revealInFinder()
                }
                .disabled(!appState.permitsDocumentInteraction)

                Divider()

                Button("スナップショットを保存") {
                    let session = appState.documentSessionToken
                    Task {
                        _ = await appState.createSnapshot(expectedSession: session)
                        await snapshotMenuPresenter.refresh()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!appState.permitsDocumentInteraction)

                SnapshotRestoreCommands(appState: appState, presenter: snapshotMenuPresenter)
                    .disabled(!appState.permitsDocumentInteraction)
            }

            CommandMenu("章") {
                Button("章を追加") {
                    Task {
                        await appState.addChapterAfterDeviceSyncDeparture()
                    }
                }
                .disabled(!appState.permitsDocumentInteraction)

                Button("選択中の章に話を追加") {
                    Task {
                        await appState.addEpisodeAfterDeviceSyncDeparture()
                    }
                }
                .disabled(!appState.permitsDocumentInteraction || appState.selectedChapter == nil)

                Button("章タイトルを編集…") {
                    NotificationCenter.default.post(name: .presentChapterTitleEditor, object: nil)
                }
                .disabled(
                    !appState.permitsDocumentInteraction ||
                        appState.workspaceSelection.section != .structure ||
                        appState.selectedChapter == nil
                )

                Button("話メモ") {
                    NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
                }
                .disabled(!appState.permitsDocumentInteraction || appState.selectedEpisode == nil)

                Divider()

                Menu("この章") {
                    ChapterContextMenuContent(
                        appState: appState,
                        onOpenCharacter: { characterID in
                            appState.selectCharacter(characterID)
                            Task { await appState.selectProjectSectionAfterDeviceSyncDeparture(.characters) }
                        },
                        onOpenPlotCard: { cardID in
                            appState.selectPlotCard(cardID)
                            Task { await appState.selectProjectSectionAfterDeviceSyncDeparture(.plot) }
                        }
                    )
                }
                .disabled(!appState.permitsDocumentInteraction || appState.selectedChapter == nil)
            }

            CommandMenu("登場人物") {
                Button("登場人物を追加") {
                    appState.addCharacter()
                }
                .disabled(!appState.permitsDocumentInteraction)
            }

            CommandMenu("プロット") {
                Button("プロットカードを追加") {
                    if case let .chapter(chapterID) = appState.plotOutlineSelection {
                        appState.addPlotCard(chapterID: chapterID)
                    } else {
                        appState.addPlotCard()
                    }
                }
                .disabled(!appState.permitsDocumentInteraction)
            }

            CommandMenu("資料") {
                Button("資料を取り込む…") {
                    NotificationCenter.default.post(name: .presentAttachmentImporter, object: nil)
                }
                .disabled(!appState.permitsDocumentInteraction || !appState.supportsAttachments)
            }

            CommandMenu("世界観") {
                Button("ノートを追加") {
                    Task {
                        guard await appState.selectProjectSectionAfterDeviceSyncDeparture(.worldbuilding) else { return }
                        appState.addWorldNote()
                    }
                }
                .disabled(!appState.permitsDocumentInteraction)
            }

            #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
            CommandMenu("AI") {
                Button("選択範囲を校正…") {
                    aiProofreadingOperation.preparePreview()
                }
                .disabled(
                    !appState.permitsLongRunningDocumentOperation ||
                        appState.workspaceSelection.section != .structure ||
                        appState.selectedEpisode == nil ||
                        aiProofreadingOperation.isRequestInFlight
                )
            }
            #endif

            CommandGroup(after: .textEditing) {
                Divider()
                WorkbenchFindCommands(
                    appState: appState,
                    editorSearchSession: editorSearchSession
                )
                .disabled(!appState.permitsDocumentInteraction)
            }

            CommandMenu("表示") {
                ForEach(ProjectSection.allCases) { section in
                    Button {
                        Task { await appState.selectProjectSectionAfterDeviceSyncDeparture(section) }
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .keyboardShortcut(section.keyboardShortcut, modifiers: .command)
                    .disabled(!appState.permitsDocumentInteraction)
                }
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
    let appState: AppState
    @Bindable var presenter: SnapshotMenuPresenter

    var body: some View {
        Menu("スナップショットを復元") {
            if presenter.snapshots.isEmpty {
                Text("スナップショットはありません")
            } else {
                ForEach(presenter.snapshots) { item in
                    Menu(item.snapshot.displayName) {
                        Button("この状態に戻す…") {
                            presenter.requestRestore(item)
                        }
                        Button("Finder で表示") {
                            guard item.session == appState.documentSessionToken else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([item.snapshot.url])
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
            editorSearchSession.jump(direction: .forward, in: appState.selectedEpisode)
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("前を検索") {
            guard appState.workspaceSelection.section == .structure else { return }
            editorSearchSession.jump(direction: .backward, in: appState.selectedEpisode)
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}
