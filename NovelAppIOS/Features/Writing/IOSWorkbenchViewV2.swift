import EditorKit
import NovelCore
import NovelSyncV2
import SwiftUI

@MainActor
struct IOSWritingEditorIdentityBoundary {
    let store: IOSDocumentStore

    @discardableResult
    func perform(_ operation: () -> Void) -> Bool {
        guard let session = store.currentDocumentSessionToken else {
            return false
        }
        let departure = IOSWorkspaceEditorDeparture(
            session: session,
            chapterID: store.selectedChapterID,
            episodeID: store.selectedEpisodeID
        )
        guard IOSWorkspaceEditorSynchronizer.synchronize(store: store, departure: departure) else {
            return false
        }
        operation()
        return true
    }
}

extension View {
    /// v2 keeps feature views usable without the retired Note/Work chrome.
    func iosWorkChrome(store _: IOSDocumentStore, accessibilityPrefix _: String) -> some View {
        self
    }
}

struct IOSAdaptiveWritingView: View {
    let store: IOSDocumentStore
    let openEpisode: (ChapterID, EpisodeID) -> Void

    var body: some View {
        List {
            ForEach(store.document.chapters) { chapter in
                Section(chapter.title.isEmpty ? "名称未設定の章" : chapter.title) {
                    ForEach(chapter.episodes) { episode in
                        Button(episode.title.isEmpty ? "名称未設定の話" : episode.title) {
                            openEpisode(chapter.id, episode.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("執筆")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("章を追加") {
                    Task { await store.addChapterAfterDeviceSyncDeparture() }
                }
            }
        }
    }
}

struct IOSWorkbenchView: View {
    @Bindable var store: IOSDocumentStore
    @Bindable var navigation: IOSWorkspaceNavigationCoordinator

    var body: some View {
        NavigationStack(path: path) {
            IOSLibraryView(store: store, openDocument: openDocument, openCloudDocument: openRemote, makeNewDocument: makeNew)
                .navigationDestination(for: IOSWorkspaceRoute.self) { route in
                    destination(route)
                }
        }
        .onAppear {
            if let session = store.currentDocumentSessionToken {
                navigation.documentDidChange(to: session)
            }
        }
    }

    private var path: Binding<[IOSWorkspaceRoute]> {
        Binding(
            get: { navigation.path },
            set: { value in
                if let departure = navigation.editorDeparture(for: value) {
                    Task {
                        guard await store.flushDeviceSyncBeforeNavigationDeparture(departure) else { return }
                        navigation.updatePath(value) { _ in true }
                    }
                } else {
                    navigation.updatePath(value) { _ in true }
                }
            }
        )
    }

    @ViewBuilder
    private func destination(_ route: IOSWorkspaceRoute) -> some View {
        switch route {
        case let .projectHome(session): IOSProjectHomeView(store: store, openWriting: { navigation.showWriting(for: session) }, openProjectInfo: { navigation.showProjectInfo(for: session) }, openPlot: { navigation.showPlot(for: session) }, openCharacters: { navigation.showCharacters(for: session) }, openWorldbuilding: { navigation.showWorldbuilding(for: session) }, openReferences: { navigation.showReferences(for: session) }, openSettings: { navigation.showSettings(for: session) })
        case .projectInfo: IOSProjectInfoView(store: store)
        case let .writing(session): IOSAdaptiveWritingView(store: store) { chapterID, episodeID in navigation.showEditor(for: session, chapterID: chapterID, episodeID: episodeID) }
        case .plot: IOSPlotFeatureView(store: store)
        case .characters: IOSCharacterFeatureView(store: store)
        case .worldbuilding: IOSWorldbuildingFeatureView(store: store)
        case .references: IOSReferencesFeatureView(store: store)
        case .settings: IOSSettingsView(store: store)
        case .editor: IOSEditorPane(store: store)
        }
    }

    private func openDocument(_ id: IOSPrivateDocumentID) {
        Task { guard await store.openPrivateDocument(id: id), let session = store.currentDocumentSessionToken else { return }; navigation.showProjectHome(for: session) }
    }

    private func openRemote(_ id: WorkID) {
        Task { guard await store.openRemoteOnly(workID: id), let session = store.currentDocumentSessionToken else { return }; navigation.showProjectHome(for: session) }
    }

    private func makeNew() {
        Task { guard await store.makeNewDocument(), let session = store.currentDocumentSessionToken else { return }; navigation.showProjectHome(for: session) }
    }
}

struct IOSEditorPane: View {
    let store: IOSDocumentStore
    @AppStorage(IOSEditorFontPreference.preferenceKey)
    private var editorFontFamilyRawValue = IOSEditorFontPreference.initialRawValue

    init(store: IOSDocumentStore, userDefaults: UserDefaults = .standard) {
        self.store = store
        _editorFontFamilyRawValue = AppStorage(
            wrappedValue: IOSEditorFontPreference.initialRawValue,
            IOSEditorFontPreference.preferenceKey,
            store: userDefaults
        )
    }

    var body: some View {
        if let chapter = store.selectedChapter,
           let episode = store.selectedEpisode,
           let editingToken = store.currentEpisodeEditingToken {
            EditorView(
                chapterKey: IOSEditorContentKey(
                    documentSession: editingToken.documentSession,
                    episodeID: episode.id,
                    editorContentGeneration: editingToken.editorContentGeneration
                ),
                initialText: episode.content,
                commandSession: store.editorCommandSession,
                configuration: IOSEditorFontPreference.configuration(
                    storedRawValue: editorFontFamilyRawValue
                ),
                onTextChange: { text in
                    store.updateEpisodeContent(
                        text,
                        chapterID: chapter.id,
                        episodeID: episode.id,
                        expectedEditingToken: editingToken
                    )
                }
            )
            .navigationTitle(episode.title)
        } else {
            ContentUnavailableView("話を選択してください", systemImage: "doc.text")
        }
    }
}
