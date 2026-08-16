import EditorKit
import NovelCore
import NovelSync
import SwiftUI
import UIKit

struct IOSWorkbenchView: View {
    @Bindable var store: IOSDocumentStore
    @Bindable var navigation: IOSWorkspaceNavigationCoordinator
    @State private var isNoteSyncConflictPresented = false

    var body: some View {
        NavigationStack(path: workspacePath) {
            IOSLibraryView(
                store: store,
                openDocument: openDocument,
                openCloudDocument: openCloudDocument,
                makeNewDocument: makeNewDocument
            )
            .navigationDestination(for: IOSWorkspaceRoute.self) { route in
                destination(for: route)
            }
        }
        .environment(\.iosNoteSyncConflictPresented, $isNoteSyncConflictPresented)
        .iosNoteSyncConflictSheet(store: store, isPresented: $isNoteSyncConflictPresented)
        .onAppear {
            synchronizeNavigationWithStore()
        }
        .onChange(of: currentDocumentSession) { _, _ in
            synchronizeNavigationWithStore()
        }
    }

    @ViewBuilder
    private func destination(for route: IOSWorkspaceRoute) -> some View {
        if currentDocumentSession == route.session {
            switch route {
            case let .projectHome(session):
                projectHome(for: session)
            case .projectInfo:
                IOSProjectInfoView(store: store)
            case let .writing(session):
                IOSAdaptiveWritingView(store: store) { chapterID, episodeID in
                    Task {
                        guard await store.selectEpisodeAfterDeviceSyncDeparture(
                            chapterID: chapterID,
                            episodeID: episodeID
                        ) else { return }
                        navigation.showEditor(
                            for: session,
                            chapterID: chapterID,
                            episodeID: episodeID
                        )
                    }
                }
            case .plot:
                IOSPlotFeatureView(store: store)
            case .characters:
                IOSCharacterFeatureView(store: store)
            case .worldbuilding:
                IOSWorldbuildingFeatureView(store: store)
            case .references:
                IOSReferencesFeatureView(store: store)
            case .settings:
                IOSSettingsView(store: store)
            case let .editor(_, chapterID, episodeID):
                IOSEditorPane(store: store)
                    .onAppear {
                        Task {
                            await store.selectEpisodeAfterDeviceSyncDeparture(
                                chapterID: chapterID,
                                episodeID: episodeID
                            )
                        }
                    }
            }
        } else {
            ContentUnavailableView {
                Label("作品を切り替えています", systemImage: "books.vertical")
            } description: {
                Text("選択した作品のホームを準備しています。")
            }
        }
    }

    private func projectHome(for session: IOSDocumentSessionToken) -> some View {
        IOSProjectHomeView(
            store: store,
            openWriting: { navigation.showWriting(for: session) },
            openProjectInfo: { navigation.showProjectInfo(for: session) },
            openPlot: { navigation.showPlot(for: session) },
            openCharacters: { navigation.showCharacters(for: session) },
            openWorldbuilding: { navigation.showWorldbuilding(for: session) },
            openReferences: { navigation.showReferences(for: session) },
            openSettings: { navigation.showSettings(for: session) }
        )
    }

    private var workspacePath: Binding<[IOSWorkspaceRoute]> {
        Binding(
            get: { navigation.path },
            set: { newPath in
                guard let departure = navigation.editorDeparture(for: newPath) else {
                    navigation.updatePath(newPath) { _ in true }
                    return
                }
                Task {
                    guard await store.flushDeviceSyncBeforeNavigationDeparture(departure) else { return }
                    navigation.updatePath(newPath) { _ in true }
                }
            }
        )
    }

    private var currentDocumentSession: IOSDocumentSessionToken? {
        store.currentDocumentSessionToken
    }

    private func synchronizeNavigationWithStore() {
        guard let currentDocumentSession else { return }
        navigation.documentDidChange(to: currentDocumentSession)
    }

    private func openDocument(_ id: IOSPrivateDocumentID) {
        Task {
            guard await store.openPrivateDocument(id: id),
                  let session = store.currentDocumentSessionToken else { return }
            navigation.showProjectHome(for: session)
        }
    }

    private func makeNewDocument() {
        Task {
            guard await store.makeNewDocument(),
                  let session = store.currentDocumentSessionToken else { return }
            navigation.showProjectHome(for: session)
        }
    }

    private func openCloudDocument(_ workID: SyncWorkID) {
        Task {
            guard await store.openCloudLibraryWork(workID),
                  let session = store.currentDocumentSessionToken else { return }
            navigation.showProjectHome(for: session)
        }
    }
}

struct IOSEditorPane: View {
    let store: IOSDocumentStore
    @AppStorage(IOSEditorFontPreference.preferenceKey)
    private var editorFontFamilyRawValue = IOSEditorFontPreference.initialRawValue
    @Environment(\.iosNoteSyncConflictPresented) private var isNoteSyncConflictPresented

    init(
        store: IOSDocumentStore,
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        _editorFontFamilyRawValue = AppStorage(
            wrappedValue: IOSEditorFontPreference.initialRawValue,
            IOSEditorFontPreference.preferenceKey,
            store: userDefaults
        )
    }

    var body: some View {
        if let identity = editingIdentity {
            IOSEditorEditingSurface(
                store: store,
                identity: identity,
                editorFontFamilyRawValue: editorFontFamilyRawValue,
                isNoteSyncConflictPresented: isNoteSyncConflictPresented
            )
        } else {
            IOSEditorMissingEpisodeView(store: store)
        }
    }

    private var editingIdentity: IOSEditorEditingIdentity? {
        guard let chapter = store.selectedChapter,
              let episode = store.selectedEpisode,
              let editingToken = store.currentEpisodeEditingToken,
              let syncLookup = store.currentDeviceSyncLookupIdentity,
              editingToken.chapterID == chapter.id,
              editingToken.episodeID == episode.id else {
            return nil
        }
        return IOSEditorEditingIdentity(
            chapter: chapter,
            episode: episode,
            editingToken: editingToken,
            syncLookup: syncLookup
        )
    }
}

private struct IOSEditorEditingIdentity {
    let chapter: Chapter
    let episode: Episode
    let editingToken: IOSEpisodeEditingToken
    let syncLookup: IOSDeviceSyncLookupIdentity
}

private struct IOSEditorMissingEpisodeView: View {
    let store: IOSDocumentStore

    var body: some View {
        ContentUnavailableView {
            Label("話を選択してください", systemImage: "doc.text")
        } description: {
            Text("章の話一覧から編集する本文を選びます。")
        } actions: {
            if store.selectedChapter != nil {
                Button("話を追加") {
                    Task {
                        await store.addEpisodeAfterDeviceSyncDeparture()
                    }
                }
            }
        }
    }
}

private struct IOSEditorEditingSurface: View {
    let store: IOSDocumentStore
    let identity: IOSEditorEditingIdentity
    let editorFontFamilyRawValue: String
    var isNoteSyncConflictPresented: Binding<Bool>
    @State private var isMemoPresented = false
    @State private var isSnapshotPresented = false
    @State private var searchQuery = ""
    @State private var searchCursor = 0
    @State private var selectionRequest: EditorSelectionRequest?
    @State private var mountedSession: IOSDocumentSessionToken?
    @State private var mountedChapterID: ChapterID?
    @State private var mountedEpisodeID: EpisodeID?
    @State private var isDeviceSyncConflictPresented = false
    @State private var isSnapshotConflictPresented = false

    var body: some View {
        snapshotHost
    }

    private var snapshotHost: some View {
        legacySyncHost
            .iosSnapshotSheet(store: store, isPresented: $isSnapshotPresented)
            .sheet(isPresented: $isSnapshotConflictPresented) {
                if let conflict = store.snapshotSyncConflict {
                    IOSSnapshotSyncConflictResolutionView(
                        conflict: conflict,
                        isApplying: store.isSnapshotSyncInFlight,
                        choose: { choice in
                            Task {
                                if await store.resolveSnapshotConflict(using: choice) {
                                    isSnapshotConflictPresented = false
                                }
                            }
                        },
                        dismiss: { isSnapshotConflictPresented = false }
                    )
                }
            }
    }

    private var legacySyncHost: some View {
        memoHost
            .iosEditorLegacySyncSheets(
                store: store,
                isPresented: $isDeviceSyncConflictPresented
            )
    }

    private var memoHost: some View {
        tooledCanvas
            .sheet(isPresented: $isMemoPresented) {
                IOSEditorMemoSheet(
                    text: episodeMemo(identity.chapter.id, identity.episode.id),
                    isPresented: $isMemoPresented
                )
            }
    }

    private var tooledCanvas: some View {
        searchedCanvas
            .toolbar {
                IOSEditorToolbarContent(
                    store: store,
                    chapter: identity.chapter,
                    episode: identity.episode,
                    isNoteSyncConflictPresented: isNoteSyncConflictPresented,
                    isSnapshotConflictPresented: $isSnapshotConflictPresented,
                    isMemoPresented: $isMemoPresented,
                    isSnapshotPresented: $isSnapshotPresented,
                    isDeviceSyncConflictPresented: $isDeviceSyncConflictPresented,
                    showsFindControls: !searchQuery.isEmpty,
                    findPrevious: { findPrevious(in: identity.episode.content) },
                    findNext: { findNext(in: identity.episode.content) }
                )
            }
    }

    private var searchedCanvas: some View {
        titledCanvas
            .searchable(text: $searchQuery, prompt: "本文を検索")
            .onSubmit(of: .search) {
                findNext(in: identity.episode.content)
            }
            .onChange(of: searchQuery) {
                searchCursor = 0
                selectionRequest = nil
            }
            .onChange(of: identity.episode.id) {
                searchQuery = ""
                searchCursor = 0
                selectionRequest = nil
                isMemoPresented = false
                captureMountedEditorIdentity(
                    chapterID: identity.chapter.id,
                    episodeID: identity.episode.id
                )
            }
            .onAppear {
                captureMountedEditorIdentity(
                    chapterID: identity.chapter.id,
                    episodeID: identity.episode.id
                )
            }
            .task(id: identity.syncLookup) {
                await store.prepareDeviceSync(for: identity.syncLookup)
            }
            .onDisappear {
                synchronizeMountedEditorBeforeDeparture()
            }
    }

    private var titledCanvas: some View {
        editorCanvas
            .navigationTitle(identity.episode.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var editorCanvas: some View {
        let isEditable = store.deviceSyncAllowsEditing(for: identity.syncLookup)
        return VStack(spacing: 0) {
            EditorView(
                chapterKey: IOSEditorContentKey(
                    documentSession: identity.editingToken.documentSession,
                    episodeID: identity.episode.id,
                    editorContentGeneration: identity.editingToken.editorContentGeneration
                ),
                initialText: identity.episode.content,
                selectionRequest: selectionRequest,
                commandSession: store.editorCommandSession,
                selectionContextMenuCommands: selectionCommands(for: identity.episode.id),
                configuration: IOSEditorFontPreference.configuration(
                    storedRawValue: editorFontFamilyRawValue
                ),
                isEditable: isEditable,
                onTextChange: { text in
                    store.updateEpisodeContent(
                        text,
                        chapterID: identity.chapter.id,
                        episodeID: identity.episode.id,
                        expectedEditingToken: identity.editingToken
                    )
                }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                IOSEditorAccessoryBar(
                    commandSession: store.editorCommandSession,
                    isEnabled: isEditable
                )
            }
        }
    }

    private func captureMountedEditorIdentity(
        chapterID: ChapterID,
        episodeID: EpisodeID
    ) {
        guard let currentSession = store.currentDocumentSessionToken else { return }
        if mountedSession == nil {
            mountedSession = currentSession
        }
        guard mountedSession == currentSession else { return }
        mountedChapterID = chapterID
        mountedEpisodeID = episodeID
    }

    private func synchronizeMountedEditorBeforeDeparture() {
        guard let mountedSession else { return }
        IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: IOSWorkspaceEditorDeparture(
                session: mountedSession,
                chapterID: mountedChapterID,
                episodeID: mountedEpisodeID
            )
        )
    }

    private func episodeMemo(_ chapterID: ChapterID, _ episodeID: EpisodeID) -> Binding<String> {
        Binding(
            get: { store.document.episode(episodeID)?.episode.memo ?? "" },
            set: { store.updateEpisodeMemo($0, chapterID: chapterID, episodeID: episodeID) }
        )
    }

    private func findNext(in text: String) {
        guard let range = TextSearch.find(
            query: searchQuery,
            in: text,
            from: searchCursor,
            direction: .forward
        ) else { return }
        selectionRequest = EditorSelectionRequest(range: range)
        searchCursor = range.location + range.length
    }

    private func findPrevious(in text: String) {
        guard let range = TextSearch.find(
            query: searchQuery,
            in: text,
            from: searchCursor,
            direction: .backward
        ) else { return }
        selectionRequest = EditorSelectionRequest(range: range)
        searchCursor = range.location
    }

    private func selectionCommands(for episodeID: EpisodeID) -> [EditorSelectionContextMenuCommand] {
        [
            EditorSelectionContextMenuCommand(
                title: "校正用プロンプトをコピー",
                systemImageName: "doc.on.clipboard"
            ) { snapshot in
                store.copySelectionPrompt(
                    text: snapshot.text,
                    purpose: .proofreading,
                    expectedEpisodeID: episodeID
                )
            },
            EditorSelectionContextMenuCommand(
                title: "アドバイス用プロンプトをコピー",
                systemImageName: "doc.on.clipboard"
            ) { snapshot in
                store.copySelectionPrompt(
                    text: snapshot.text,
                    purpose: .advice,
                    expectedEpisodeID: episodeID
                )
            }
        ]
    }
}

private struct IOSEditorToolbarContent: ToolbarContent {
    let store: IOSDocumentStore
    let chapter: Chapter
    let episode: Episode
    var isNoteSyncConflictPresented: Binding<Bool>
    @Binding var isSnapshotConflictPresented: Bool
    @Binding var isMemoPresented: Bool
    @Binding var isSnapshotPresented: Bool
    @Binding var isDeviceSyncConflictPresented: Bool
    let showsFindControls: Bool
    let findPrevious: () -> Void
    let findNext: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            IOSWorkSaveStatusButton(
                store: store,
                accessibilityIdentifier: "ios.editor.saveState",
                isNoteSyncConflictPresented: isNoteSyncConflictPresented,
                isSnapshotConflictPresented: $isSnapshotConflictPresented,
                isDeviceSyncConflictPresented: $isDeviceSyncConflictPresented
            )
            if store.canExplicitlySyncCurrentWork {
                IOSWorkExplicitSyncButton(
                    store: store,
                    accessibilityIdentifier: "ios.editor.sync"
                )
            }
            memoButton
            IOSSnapshotToolbarButton(
                accessibilityIdentifier: "ios.editor.snapshot",
                isPresented: $isSnapshotPresented
            )
            IOSEditorPromptMenu(store: store, chapter: chapter, episode: episode)
            if showsFindControls {
                findControls
            }
        }
    }

    private var memoButton: some View {
        Button {
            isMemoPresented = true
        } label: {
            Label("話メモ", systemImage: "note.text")
        }
    }

    private var findControls: some View {
        Group {
            Button(action: findPrevious) {
                Label("前を検索", systemImage: "chevron.up")
            }
            Button(action: findNext) {
                Label("次を検索", systemImage: "chevron.down")
            }
        }
    }
}

private struct IOSEditorPromptMenu: View {
    let store: IOSDocumentStore
    let chapter: Chapter
    let episode: Episode

    var body: some View {
        Menu {
            Section("この話") {
                Button("校正用プロンプトをコピー") {
                    store.copyEpisodePrompt(purpose: .proofreading, expectedEpisodeID: episode.id)
                }
                Button("アドバイス用プロンプトをコピー") {
                    store.copyEpisodePrompt(purpose: .advice, expectedEpisodeID: episode.id)
                }
            }
            Section("この章") {
                Button("校正用プロンプトをコピー") {
                    store.copyChapterPrompt(purpose: .proofreading, expectedChapterID: chapter.id)
                }
                Button("アドバイス用プロンプトをコピー") {
                    store.copyChapterPrompt(purpose: .advice, expectedChapterID: chapter.id)
                }
            }
        } label: {
            Label("プロンプトをコピー", systemImage: "doc.on.clipboard")
        }
    }
}

private struct IOSEditorMemoSheet: View {
    @Binding var text: String
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("話メモ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            isPresented = false
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
