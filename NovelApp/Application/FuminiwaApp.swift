import AppKit
import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelLocalStore
import SwiftUI

/// アプリのエントリポイント(docs/DESIGN.md 5.3)。
///
/// v1 では `DocumentGroup` は使わず、単一ウィンドウ + 明示的な Repository 構成とする
/// (D-010)。起動時の作品選択・Finder指定作品の読み込みは `AppState.bootstrap()` に委譲し、
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
    #if canImport(NovelSyncCloudKit)
    @State private var deviceSyncComposition: DeviceSyncProductionComposition?
    #endif

    init() {
        let defaults = UserDefaults.standard
        if AppBuildFlavor.migratesLegacyPreferences {
            LegacyPreferenceMigration.migrateIfNeeded(to: defaults)
        }

        let editorCommandSession = EditorCommandSession()
        #if canImport(NovelSyncCloudKit)
        // D-078 cutover: CloudKit remains compiled for migration/tests, but
        // the live app uses SQLite + the Rust Snapshot Sync server. Creating
        // the legacy composition here would still start its preparation gate
        // and surface a misleading iCloud retry state after a successful
        // local commit.
        let deviceSyncComposition: DeviceSyncProductionComposition? = nil
        let deviceSyncRuntime = deviceSyncComposition?.runtime
        #endif
        let syncServerURL = URL(
            string: defaults.string(forKey: "fuminiwa.syncServerURL")
                ?? "http://192.168.11.5:18080"
        ) ?? URL(string: "http://192.168.11.5:18080")!
        let authTransport = FuminiwaHTTPAuthTransport(baseURL: syncServerURL)
        #if canImport(Security)
        let authSessionCoordinator = AuthSessionCoordinator(
            transport: authTransport,
            vault: KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync")
        )
        #else
        let authSessionCoordinator: AuthSessionCoordinator? = nil
        #endif
        let appleSignInCoordinator = AppleSignInCoordinator()
        let appState = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                defaultDocumentDirectoryName: AppBuildFlavor.defaultDocumentDirectoryName,
                editorCommandSession: editorCommandSession,
                deviceSyncRuntime: deviceSyncRuntime,
                authSessionCoordinator: authSessionCoordinator,
                appleSignInCoordinator: appleSignInCoordinator,
                snapshotSyncTransport: FuminiwaHTTPSnapshotSyncTransport(baseURL: syncServerURL)
            )
        )
        #if canImport(NovelSyncCloudKit)
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
        #if canImport(NovelSyncCloudKit)
        _deviceSyncComposition = State(initialValue: deviceSyncComposition)
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
                .task {
                    applicationDelegate.attach(appState: appState)
                    let startupOpenURL = applicationDelegate.takeStartupOpenURL()
                    await appState.restoreFuminiwaSession()
                    #if canImport(NovelSyncCloudKit)
                    let deviceSyncBootstrap = deviceSyncComposition.map { composition in
                        Task { await composition.bootstrap() }
                    }
                    #endif
                    await appState.bootstrap(opening: startupOpenURL, localFirst: true)
                    await appState.resumePendingSnapshotSync()
                    applicationDelegate.finishBootstrap()
                    #if canImport(NovelSyncCloudKit)
                    // local shelf／active editorの表示をCloudKit bootstrapや
                    // remote catalogの完了へ結び付けない。必要なremote処理は
                    // bootstrap完了後にsingle-flightのbackground laneへ渡す。
                    if let deviceSyncBootstrap {
                        Task { @MainActor in
                            await deviceSyncBootstrap.value
                            await appState.refreshStartupLibrary()
                            await appState.refreshOrPrepareSelectedEpisodeDeviceSync()
                        }
                    }
                    #endif
                }
        }
        .commands {
            CommandMenu("アカウント") {
                switch appState.authUIState {
                case .signedIn:
                    Button("サインアウト") {
                        Task { await appState.signOutFromFuminiwa() }
                    }
                case .unavailable, .signedOut, .failed:
                    Button("Appleでサインイン") {
                        Task { await appState.signInWithApple() }
                    }
                case .signingIn:
                    Button("Appleでサインイン中…") {}
                        .disabled(true)
                }
            }

            // 新規作品はこのアプリの作品ライフサイクルの入口であり、`WindowGroup`
            // 既定の「新規ウインドウ」(単一ウィンドウ方針 D-010 と衝突する)を
            // 置き換える。
            CommandGroup(replacing: .newItem) {
                Button("新しい作品") {
                    documentPanelPresenter.presentNewDocument()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!appState.permitsDocumentChoice)

                Button("作品を取り込む…") {
                    documentPanelPresenter.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!appState.permitsDocumentChoice)
            }

            CommandGroup(replacing: .saveItem) {
                if appState.canExplicitlySyncCurrentWork {
                    Button(appState.usesSnapshotSyncRuntime ? "サーバーと同期" : "iCloudと同期") {
                        Task {
                            if appState.usesSnapshotSyncRuntime {
                                _ = await appState.saveAndSyncSnapshotNow()
                            } else {
                                _ = await appState.saveAndSyncNow()
                            }
                        }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(
                        !appState.permitsDocumentInteraction || appState.isExplicitNoteSyncInFlight
                    )
                } else {
                    Button("保存") {
                        Task { await appState.saveNow() }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!appState.permitsDocumentInteraction)
                }
            }

            // app-private作業コピーを外へ見せず、portable `.novelpkg`は書き出しから
            // 明示的に作る。スナップショット保存は Cmd+Option+S を維持する。
            CommandGroup(after: .saveItem) {
                if appState.deviceSyncRuntime?.library != nil {
                    Button("作品を選ぶ") {
                        let session = appState.documentSessionToken
                        Task {
                            _ = await appState.returnToStartupLibrary(
                                expectedSession: session,
                                localFirst: true
                            )
                        }
                    }
                    .disabled(!appState.permitsReturnToCloudLibrary)

                    Button("iCloudに保存") {
                        let session = appState.documentSessionToken
                        Task {
                            _ = await appState.publishCurrentLibraryWork(
                                expectedSession: session
                            )
                        }
                    }
                    .disabled(!appState.canPublishCurrentWorkToCloud)

                    Divider()
                }

                Button("書き出す…") {
                    exportPresenter.present()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.permitsDocumentInteraction || exportPresenter.state.isExporting)

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
                    Button(item.snapshot.displayName) {
                        presenter.requestRestore(item)
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
