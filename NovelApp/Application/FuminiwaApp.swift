import AppKit
import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelSyncV2Application
import NovelSyncV2Runtime
import SwiftUI

@main
struct FuminiwaApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var appState: AppState
    @State private var editorSettings: EditorSettings
    @State private var documentPanelPresenter: DocumentPanelPresenter
    @State private var snapshotMenuPresenter: SnapshotMenuPresenter
    @State private var exportPresenter: ExportPresenter
    @State private var editorSearchSession: EditorSearchSession
    @State private var editorCommandSession: EditorCommandSession

    init() {
        let defaults = FuminiwaRuntimeEnvironment.applicationUserDefaults()
        let editorCommandSession = EditorCommandSession()
        let dependencies = Self.makeDependencies(
            userDefaults: defaults,
            editorCommandSession: editorCommandSession
        )
        let appState = AppState(dependencies: dependencies)
        _appState = State(initialValue: appState)
        _editorSettings = State(initialValue: EditorSettings(userDefaults: defaults))
        _documentPanelPresenter = State(initialValue: DocumentPanelPresenter(appState: appState))
        _snapshotMenuPresenter = State(initialValue: SnapshotMenuPresenter(appState: appState))
        _exportPresenter = State(initialValue: ExportPresenter(appState: appState))
        _editorSearchSession = State(initialValue: EditorSearchSession())
        _editorCommandSession = State(initialValue: editorCommandSession)
    }

    static func makeDependencies(
        userDefaults: UserDefaults,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppDependencies {
        let environment = FuminiwaRuntimeEnvironment(
            userDefaults: userDefaults,
            environment: processEnvironment
        )
        let platformGate = MacSyncV2DocumentGate()
        let explicitOrigin = environment.syncServerURL.flatMap { try? ProductionHTTPSOrigin(url: $0) }

        #if canImport(Security)
        let authVault: (any AuthSessionVault)? = KeychainAuthSessionVault(
            service: "dev.serikayuzuki.fuminiwa.sync"
        )
        #else
        let authVault: (any AuthSessionVault)? = nil
        #endif

        let authCoordinator: AuthSessionCoordinator? = if let authVault,
                                                          let explicitOrigin,
                                                          let configuration = try? AuthClientConfiguration(
                                                              origin: explicitOrigin.url,
                                                              clientVersion: "0.1.0",
                                                              clientPlatform: .macos
                                                          ),
                                                          let limits = try? AuthLimits(
                                                              accessTokenLifetimeSeconds: 900,
                                                              authReceiptLifetimeSeconds: 86400,
                                                              challengeLifetimeSeconds: 300,
                                                              maxCanonicalCommandBytes: 65536,
                                                              maxProviderClockSkewSeconds: 300,
                                                              refreshTokenLifetimeSeconds: 86400
                                                          ),
                                                          let transport = try? FuminiwaHTTPAuthTransport(configuration: configuration) {
            AuthSessionCoordinator(
                transport: transport,
                vault: authVault,
                authLimits: limits
            )
        } else {
            nil
        }

        let appleSignInCoordinator = AppleSignInCoordinator()
        #if canImport(AuthenticationServices)
        let orchestrator: AppleAuthenticationOrchestrator? = if let authCoordinator {
            AppleAuthenticationOrchestrator(
                authSessionCoordinator: authCoordinator,
                authorizationProvider: appleSignInCoordinator,
                credentialStateHandleVault: KeychainAppleCredentialStateHandleVault(),
                credentialStateProvider: SystemAppleCredentialStateProvider()
            )
        } else {
            nil
        }
        #else
        let orchestrator: AppleAuthenticationOrchestrator? = nil
        #endif

        let factory: (@Sendable () async throws -> SyncV2Application)? = {
            if environment.isTestProcess {
                let configuration = try TestRuntimeConfiguration()
                return try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
            }
            // The production configuration is typed and always receives the
            // Keychain vault plus the macOS gate. The runtime opens SQLite
            // even when the HTTPS lane is unreachable; it reports offline.
            let configuration = try ProductionRuntimeConfiguration(
                origin: explicitOrigin,
                vault: authVault,
                documentGate: platformGate,
                clientVersion: "0.1.0",
                clientPlatform: .macos
            )
            return try await SnapshotSyncV2Runtime.makeApplication(mode: .production(configuration))
        }

        return AppDependencies(
            userDefaults: userDefaults,
            defaultDocumentDirectoryName: environment.isTestProcess
                ? "\(AppBuildFlavor.defaultDocumentDirectoryName)-TestHost"
                : AppBuildFlavor.defaultDocumentDirectoryName,
            editorCommandSession: editorCommandSession,
            authSessionCoordinator: authCoordinator,
            appleSignInCoordinator: appleSignInCoordinator,
            appleAuthenticationOrchestrator: orchestrator,
            snapshotSyncV2Factory: factory,
            snapshotSyncV2DocumentGate: platformGate
        )
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
                    let opening = applicationDelegate.takeStartupOpenURL()
                    guard await appState.configureSnapshotSyncV2(using: appState.snapshotSyncV2Factory) else {
                        applicationDelegate.finishBootstrap()
                        return
                    }
                    // Apple credential-state lookup is advisory and may cross
                    // a system/network boundary. It must not hold the local
                    // SQLite bootstrap or first editor frame.
                    Task { @MainActor in
                        await appState.restoreFuminiwaSession()
                        await appState.refreshSnapshotLibrary()
                        await appState.refreshSnapshotRemoteCatalog()
                    }
                    await appState.bootstrap(opening: opening)
                    await appState.resumeSnapshotSyncV2()
                    applicationDelegate.finishBootstrap()
                }
        }
        .commands {
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
                Button("この端末に保存") {
                    Task { _ = await appState.saveNow() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.permitsDocumentInteraction)
            }
            CommandGroup(after: .saveItem) {
                Button("書き出す…") {
                    exportPresenter.present()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.permitsDocumentInteraction || exportPresenter.state.isExporting)

                Divider()

                Button("スナップショットを保存") {
                    Task {
                        _ = await appState.checkpointSnapshotSyncV2(
                            appState.document,
                            reason: .explicit
                        )
                        await snapshotMenuPresenter.refresh()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!appState.permitsDocumentInteraction)

                SnapshotRestoreCommands(
                    appState: appState,
                    presenter: snapshotMenuPresenter
                )
                .disabled(!appState.permitsDocumentInteraction)
            }
            CommandMenu("アカウント") {
                switch appState.authUIState {
                case .signedIn:
                    Button("サインアウト") { Task { await appState.signOutFromFuminiwa() } }
                case .signingIn:
                    Button("Appleでサインイン中…") {}
                        .disabled(true)
                case .signedOut, .unavailable, .failed:
                    Button("Appleでサインイン") { Task { await appState.signInWithApple() } }
                }
            }
            CommandMenu("章") {
                Button("章を追加") {
                    Task { _ = await appState.addChapterAfterTransition() }
                }
                .disabled(!appState.permitsDocumentInteraction)
                Button("話を追加") {
                    Task { _ = await appState.addEpisodeAfterTransition() }
                }
                .disabled(!appState.permitsDocumentInteraction)
                Button("話メモ") {
                    NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
                }
                .disabled(!appState.permitsDocumentInteraction || appState.selectedEpisode == nil)

                Button("章タイトルを編集…") {
                    NotificationCenter.default.post(name: .presentChapterTitleEditor, object: nil)
                }
                .disabled(
                    !appState.permitsDocumentInteraction ||
                        appState.workspaceSelection.section != .structure ||
                        appState.selectedChapter == nil
                )

                Divider()

                Menu("この章") {
                    ChapterContextMenuContent(
                        appState: appState,
                        onOpenCharacter: { characterID in
                            appState.selectCharacter(characterID)
                            Task { await appState.selectProjectSectionAfterTransition(.characters) }
                        },
                        onOpenPlotCard: { cardID in
                            appState.selectPlotCard(cardID)
                            Task { await appState.selectProjectSectionAfterTransition(.plot) }
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
                        guard await appState.selectProjectSectionAfterTransition(.worldbuilding) else { return }
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
                        Task { await appState.selectProjectSectionAfterTransition(section) }
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
                    Button(item.entry.reason) {
                        Task { await presenter.restore(item) }
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
