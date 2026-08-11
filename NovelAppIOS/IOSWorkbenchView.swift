import EditorKit
import NovelCore
import SwiftUI
import UIKit

struct IOSWorkbenchView: View {
    @Bindable var store: IOSDocumentStore
    @Bindable var navigation: IOSWorkspaceNavigationCoordinator

    var body: some View {
        NavigationStack(path: workspacePath) {
            IOSLibraryView(
                store: store,
                openDocument: openDocument,
                makeNewDocument: makeNewDocument
            )
            .navigationDestination(for: IOSWorkspaceRoute.self) { route in
                destination(for: route)
            }
        }
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
}

struct IOSEditorPane: View {
    let store: IOSDocumentStore
    @AppStorage(IOSEditorFontPreference.preferenceKey)
    private var editorFontFamilyRawValue = IOSEditorFontPreference.initialRawValue
    @State private var isMemoPresented = false
    @State private var searchQuery = ""
    @State private var searchCursor = 0
    @State private var selectionRequest: EditorSelectionRequest?
    @State private var mountedSession: IOSDocumentSessionToken?
    @State private var mountedChapterID: ChapterID?
    @State private var mountedEpisodeID: EpisodeID?
    @State private var isDeviceSyncConflictPresented = false

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
        if let chapter = store.selectedChapter,
           let episode = store.selectedEpisode,
           let editingToken = store.currentEpisodeEditingToken,
           let syncLookup = store.currentDeviceSyncLookupIdentity,
           editingToken.chapterID == chapter.id,
           editingToken.episodeID == episode.id {
            let isEditable = store.deviceSyncAllowsEditing(for: syncLookup)
            VStack(spacing: 0) {
                EditorView(
                    chapterKey: IOSEditorContentKey(
                        documentSession: editingToken.documentSession,
                        episodeID: episode.id,
                        editorContentGeneration: editingToken.editorContentGeneration
                    ),
                    initialText: episode.content,
                    selectionRequest: selectionRequest,
                    commandSession: store.editorCommandSession,
                    selectionContextMenuCommands: selectionCommands(for: episode.id),
                    configuration: IOSEditorFontPreference.configuration(
                        storedRawValue: editorFontFamilyRawValue
                    ),
                    isEditable: isEditable,
                    onTextChange: { text in
                        store.updateEpisodeContent(
                            text,
                            chapterID: chapter.id,
                            episodeID: episode.id,
                            expectedEditingToken: editingToken
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
            .navigationTitle(episode.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "本文を検索")
            .onSubmit(of: .search) {
                findNext(in: episode.content)
            }
            .onChange(of: searchQuery) {
                searchCursor = 0
                selectionRequest = nil
            }
            .onChange(of: episode.id) {
                searchQuery = ""
                searchCursor = 0
                selectionRequest = nil
                isMemoPresented = false
                captureMountedEditorIdentity(
                    chapterID: chapter.id,
                    episodeID: episode.id
                )
            }
            .onAppear {
                captureMountedEditorIdentity(
                    chapterID: chapter.id,
                    episodeID: episode.id
                )
            }
            .task(id: syncLookup) {
                await store.prepareDeviceSync(for: syncLookup)
            }
            .onDisappear {
                synchronizeMountedEditorBeforeDeparture()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    IOSDeviceSyncStatusControl(
                        saveState: store.saveState,
                        state: store.deviceSyncState,
                        transferState: store.deviceSyncTransferState,
                        localDurabilityState: store.deviceSyncLocalDurabilityState,
                        hasLocalRecoveryReview: store.deviceSyncLocalRecoveryReview != nil
                            || store.workSyncLocalRecoveryReview != nil
                            || store.workSyncConflictReview != nil,
                        isLocalRecoveryReviewReady: store.workSyncLocalRecoveryReview != nil
                            || !store.deviceSyncLocalRecoveryPending,
                        usesWholeWorkSync: store.usesWholeWorkDeviceSync
                    ) {
                        guard store.workSyncLocalRecoveryReview != nil
                            || store.workSyncConflictReview != nil
                            || store.deviceSyncConflict != nil
                            || store.deviceSyncLocalRecoveryReview != nil else { return }
                        isDeviceSyncConflictPresented = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("ios.editor.saveState")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isMemoPresented = true
                    } label: {
                        Label("話メモ", systemImage: "note.text")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    promptMenu(chapter: chapter, episode: episode)
                }
                if !searchQuery.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            findPrevious(in: episode.content)
                        } label: {
                            Label("前を検索", systemImage: "chevron.up")
                        }
                        Button {
                            findNext(in: episode.content)
                        } label: {
                            Label("次を検索", systemImage: "chevron.down")
                        }
                    }
                }
            }
            .sheet(isPresented: $isMemoPresented) {
                NavigationStack {
                    TextEditor(text: episodeMemo(chapter.id, episode.id))
                        .padding()
                        .navigationTitle("話メモ")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完了") {
                                    isMemoPresented = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isDeviceSyncConflictPresented) {
                if let recovery = store.workSyncLocalRecoveryReview {
                    let adapter = IOSWorkLocalRecoveryPresentation(review: recovery)
                    IOSWorkConflictResolutionView(
                        presentation: adapter.presentation,
                        isApplying: store.workSyncIsApplyingConflict,
                        mode: .localRecovery
                    ) { choice in
                        Task {
                            await store.resolveWorkSyncLocalRecovery(
                                using: choice,
                                expectedReview: recovery
                            )
                        }
                    } reviewLater: {
                        isDeviceSyncConflictPresented = false
                    }
                    .id("local-\(adapter.presentation.local.id)")
                } else if let review = store.workSyncConflictReview {
                    IOSWorkConflictResolutionView(
                        presentation: IOSWorkConflictReviewPresentation(review: review),
                        isApplying: store.workSyncIsApplyingConflict
                    ) { choice in
                        Task {
                            await store.resolveWorkSyncConflict(
                                using: choice,
                                expectedReview: review
                            )
                        }
                    } reviewLater: {
                        isDeviceSyncConflictPresented = false
                    }
                    .id(review.id)
                } else if let conflict = store.deviceSyncConflict {
                    IOSDeviceSyncConflictResolutionView(
                        conflict: conflict,
                        state: store.deviceSyncState,
                        recoveredContent: store.pendingDeviceSyncConflictResolution.flatMap {
                            $0.conflict == conflict ? $0.content : nil
                        }
                    ) { choice in
                        Task {
                            await store.resolveDeviceSyncConflict(
                                using: choice,
                                expectedConflict: conflict
                            )
                        }
                    }
                    .id(conflict)
                } else if let review = store.deviceSyncLocalRecoveryReview,
                          let currentContent = store.selectedEpisode?.content {
                    IOSDeviceSyncLocalRecoveryReviewView(
                        review: review,
                        currentContent: currentContent
                    ) { choice in
                        Task {
                            await store.resolveDeviceSyncLocalRecovery(
                                using: choice,
                                expectedReview: review
                            )
                        }
                    }
                    .id(review)
                }
            }
            .onChange(of: store.workSyncLocalRecoveryReview) { _, recovery in
                if recovery == nil,
                   store.workSyncConflictReview == nil,
                   store.deviceSyncConflict == nil,
                   store.deviceSyncLocalRecoveryReview == nil {
                    isDeviceSyncConflictPresented = false
                }
            }
            .onChange(of: store.workSyncConflictReview?.id) { _, reviewID in
                if reviewID == nil,
                   store.workSyncLocalRecoveryReview == nil,
                   store.deviceSyncConflict == nil,
                   store.deviceSyncLocalRecoveryReview == nil {
                    isDeviceSyncConflictPresented = false
                }
            }
            .onChange(of: store.deviceSyncConflict) { _, conflict in
                if conflict == nil,
                   store.workSyncLocalRecoveryReview == nil,
                   store.deviceSyncLocalRecoveryReview == nil,
                   store.workSyncConflictReview == nil {
                    isDeviceSyncConflictPresented = false
                }
            }
            .onChange(of: store.deviceSyncLocalRecoveryReview) { _, review in
                if review == nil,
                   store.workSyncLocalRecoveryReview == nil,
                   store.deviceSyncConflict == nil,
                   store.workSyncConflictReview == nil {
                    isDeviceSyncConflictPresented = false
                }
            }
        } else {
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

    private func promptMenu(chapter: Chapter, episode: Episode) -> some View {
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
