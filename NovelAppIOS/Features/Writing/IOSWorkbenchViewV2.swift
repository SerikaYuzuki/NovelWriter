import EditorKit
import NovelCore
import NovelSyncV2
import NovelUI
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

@MainActor
enum IOSAdaptiveWritingLayoutTransition {
    static func nextSizeClass(
        from currentSizeClass: UserInterfaceSizeClass?,
        to proposedSizeClass: UserInterfaceSizeClass?,
        synchronizeBeforeEditorRemoval: () -> Bool
    ) -> UserInterfaceSizeClass? {
        guard currentSizeClass == .regular, proposedSizeClass != .regular else {
            return proposedSizeClass
        }
        return synchronizeBeforeEditorRemoval() ? proposedSizeClass : currentSizeClass
    }
}

@MainActor
struct IOSAdaptiveWritingView: View {
    let store: IOSDocumentStore
    let openEpisode: (ChapterID, EpisodeID) -> Void
    let expectedSession: IOSDocumentSessionToken?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var toolDestination: IOSWritingTool?
    @State private var regularProjectSection: IOSRegularProjectSection? = .writing
    @State private var presentedHorizontalSizeClass: UserInterfaceSizeClass?
    @State private var selectedPlotItem: IOSPlotSelection?
    @State private var selectedCharacterID: CharacterID?
    @State private var selectedWorldNoteID: WorldNoteID?
    @State private var selectedFeedbackID: UUID?
    @State private var selectedReferenceFileName: String?

    init(
        store: IOSDocumentStore,
        openEpisode: @escaping (ChapterID, EpisodeID) -> Void
    ) {
        self.store = store
        self.openEpisode = openEpisode
        expectedSession = store.currentDocumentSessionToken
    }

    var body: some View {
        Group {
            if effectiveHorizontalSizeClass == .regular {
                regularLayout
            } else {
                IOSWritingOutlineList(store: store, openEpisode: openEpisode, presentTool: presentTool)
            }
        }
        .modifier(IOSWritingToolPresentationModifier(store: store, destination: $toolDestination))
        .modifier(WritingSyncPulse(host: store.writingAssistantHost))
        .environment(\.horizontalSizeClass, effectiveHorizontalSizeClass)
        .onAppear {
            if presentedHorizontalSizeClass == nil {
                presentedHorizontalSizeClass = horizontalSizeClass
            }
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            let currentSizeClass = presentedHorizontalSizeClass
            guard currentSizeClass == .regular, newSizeClass != .regular else {
                presentedHorizontalSizeClass = newSizeClass
                return
            }
            Task { @MainActor in
                guard presentedHorizontalSizeClass == currentSizeClass,
                      await store.prepareForEditorSurfaceDeparture(),
                      presentedHorizontalSizeClass == currentSizeClass else { return }
                presentedHorizontalSizeClass = newSizeClass
            }
        }
    }

    private var effectiveHorizontalSizeClass: UserInterfaceSizeClass? {
        presentedHorizontalSizeClass ?? horizontalSizeClass
    }

    private var regularLayout: some View {
        NavigationSplitView {
            regularProjectSidebar
        } detail: {
            if regularSectionHasOutline {
                NavigationSplitView {
                    regularContent
                } detail: {
                    regularDetail
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                regularDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var regularSectionHasOutline: Bool {
        regularProjectSection != .projectInfo && regularProjectSection != .settings
    }

    @ViewBuilder
    private var regularContent: some View {
        switch regularProjectSection ?? .writing {
        case .writing:
            IOSWritingOutlineList(store: store, openEpisode: { chapterID, episodeID in
                Task {
                    guard await store.selectEpisodeAfterDeviceSyncDeparture(
                        chapterID: chapterID,
                        episodeID: episodeID
                    ) else { return }
                    openEpisode(chapterID, episodeID)
                }
            }, presentTool: presentTool)
        case .plot:
            IOSPlotOutlineView(
                store: store,
                selection: $selectedPlotItem,
                expectedSession: expectedSession,
                usesNavigationLinks: false
            )
        case .characters:
            IOSCharacterOutlineView(
                store: store,
                selection: $selectedCharacterID,
                expectedSession: expectedSession,
                usesNavigationLinks: false
            )
        case .worldbuilding:
            IOSWorldNoteOutlineView(
                store: store,
                selection: $selectedWorldNoteID,
                expectedSession: expectedSession,
                usesNavigationLinks: false
            )
        case .feedback:
            IOSAssistantFeedbackOutline(store: store, selection: $selectedFeedbackID)
        case .references:
            IOSReferencesOutlineView(
                store: store,
                selection: $selectedReferenceFileName,
                expectedSession: expectedSession,
                usesNavigationLinks: false
            )
        case .projectInfo, .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private var regularDetail: some View {
        switch regularProjectSection ?? .writing {
        case .projectInfo:
            IOSProjectInfoView(store: store)
        case .writing:
            IOSEditorPane(store: store, userDefaults: store.userDefaults)
        case .plot:
            IOSPlotDetailView(
                store: store,
                selection: selectedPlotItem,
                expectedSession: expectedSession,
                onDeletion: { selectedPlotItem = nil }
            )
        case .characters:
            IOSCharacterDetailView(
                store: store,
                characterID: selectedCharacterID,
                expectedSession: expectedSession,
                onDeletion: { selectedCharacterID = nil }
            )
        case .worldbuilding:
            IOSWorldNoteDetailView(
                store: store,
                noteID: selectedWorldNoteID,
                expectedSession: expectedSession,
                onDeletion: { selectedWorldNoteID = nil }
            )
        case .feedback:
            AssistantFeedbackDetail(record: store.assistantFeedback.first { $0.id == selectedFeedbackID })
        case .references:
            IOSReferenceDetailView(
                store: store,
                fileName: selectedReferenceFileName,
                expectedSession: expectedSession,
                onDeletion: { selectedReferenceFileName = nil }
            )
        case .settings:
            IOSSettingsView(store: store, userDefaults: store.userDefaults)
        }
    }

    private var regularProjectSidebar: some View {
        IOSRegularProjectSidebar(
            store: store,
            selection: regularProjectSectionSelection
        )
    }

    private var regularProjectSectionSelection: Binding<IOSRegularProjectSection?> {
        Binding(
            get: { regularProjectSection },
            set: { newSection in
                guard newSection != regularProjectSection else { return }
                let previousSection = regularProjectSection
                Task { @MainActor in
                    guard regularProjectSection == previousSection,
                          await store.prepareForEditorSurfaceDeparture(),
                          regularProjectSection == previousSection else { return }
                    regularProjectSection = newSection
                }
            }
        )
    }

    private func presentTool(_ destination: IOSWritingTool) {
        let scope = store.workSearchScope
        Task {
            guard await store.prepareForEditorSurfaceDeparture(), store.workSearchScope == scope else { return }
            if destination == .textCheck {
                store.synchronizeTextCheck()
            }
            toolDestination = destination
        }
    }
}

private struct IOSWritingOutlineList: View {
    let store: IOSDocumentStore
    let openEpisode: (ChapterID, EpisodeID) -> Void
    let presentTool: (IOSWritingTool) -> Void

    var body: some View {
        List {
            ForEach(store.document.chapters) { chapter in
                IOSWritingChapterSection(
                    store: store,
                    chapter: chapter,
                    openEpisode: openEpisode
                )
            }
            .onMove { offsets, destination in
                Task {
                    _ = await store.moveChaptersAfterDeviceSyncDeparture(
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                }
            }
        }
        .navigationTitle("執筆")
        .overlay {
            if store.document.chapters.isEmpty {
                ContentUnavailableView {
                    Label("章がありません", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("章を追加すると、話を作って本文を書けます。")
                } actions: {
                    Button("章を追加") {
                        Task {
                            _ = await store.addChapterAfterDeviceSyncDeparture()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        _ = await store.addChapterAfterDeviceSyncDeparture()
                    }
                } label: {
                    Label("章を追加", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("作品全体を検索", systemImage: "text.magnifyingglass") {
                        presentTool(.workSearch)
                    }
                    Button("表記をチェック", systemImage: "text.badge.checkmark") {
                        presentTool(.textCheck)
                    }
                } label: { Label("執筆のメニュー", systemImage: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .modifier(IOSWritingOutlineSurfaceModifier())
    }
}

private struct IOSWritingChapterSection: View {
    let store: IOSDocumentStore
    let chapter: Chapter
    let openEpisode: (ChapterID, EpisodeID) -> Void

    var body: some View {
        Section {
            ForEach(chapter.episodes) { episode in
                Button {
                    openEpisode(chapter.id, episode.id)
                } label: {
                    IOSEpisodeOutlineRow(episode: episode)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios.outline.episode.\(episode.id)")
                .modifier(IOSEpisodeRenameModifier(store: store, chapterID: chapter.id, episode: episode, titleMenu: false))
            }
            .onDelete { offsets in
                Task { @MainActor in
                    _ = await store.deleteEpisodesAfterDeviceSyncDeparture(
                        at: offsets,
                        chapterID: chapter.id
                    )
                }
            }
            .onMove { offsets, destination in
                Task { @MainActor in
                    _ = await store.moveEpisodesAfterDeviceSyncDeparture(
                        in: chapter.id,
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                }
            }
        } header: {
            HStack(spacing: 8) {
                TextField("章タイトル", text: chapterTitle)
                    .font(.headline)
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("章タイトル")

                Spacer(minLength: 8)

                Button {
                    Task { @MainActor in
                        _ = await store.addEpisodeAfterDeviceSyncDeparture(to: chapter.id)
                    }
                } label: {
                    Label("話を追加", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("「\(chapterDisplayTitle)」に話を追加")
                .accessibilityIdentifier("ios.outline.chapter.\(chapter.id).addEpisode")
            }
        }
    }

    private var chapterTitle: Binding<String> {
        Binding(
            get: {
                store.document.chapters.first(where: { $0.id == chapter.id })?.title ?? ""
            },
            set: { store.updateChapterTitle($0, chapterID: chapter.id) }
        )
    }

    private var chapterDisplayTitle: String {
        chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称未設定の章"
            : chapter.title
    }
}

private struct IOSWritingOutlineSurfaceModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(.thinMaterial)
        } else {
            content
                .listStyle(.insetGrouped)
        }
    }
}

private struct IOSEpisodeOutlineRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text")
                .foregroundStyle(FuminiwaColor.accent.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title.isEmpty ? "名称未設定の話" : episode.title)
                    .foregroundStyle(.primary)
                Text("\(ManuscriptMetrics.countCharacters(in: episode.content))字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(episode.title.isEmpty ? "名称未設定の話" : episode.title)
        .accessibilityValue("\(ManuscriptMetrics.countCharacters(in: episode.content))字")
        .accessibilityHint("本文を開きます。")
    }
}

struct IOSWorkbenchView: View {
    @Bindable var store: IOSDocumentStore
    @Bindable var navigation: IOSWorkspaceNavigationCoordinator

    var body: some View {
        NavigationStack(path: path) {
            IOSLibraryView(
                store: store,
                openWork: openWork,
                makeNewDocument: makeNew
            )
            .navigationDestination(for: IOSWorkspaceRoute.self) { route in
                destination(route)
            }
        }
        .onAppear {
            if let session = store.currentDocumentSessionToken {
                navigation.documentDidChange(to: session)
            } else {
                navigation.documentDidBecomeUnavailable()
            }
        }
        .onChange(of: store.currentDocumentSessionToken) { _, session in
            if let session {
                navigation.documentDidChange(to: session)
            } else {
                navigation.documentDidBecomeUnavailable()
            }
        }
    }

    private var path: Binding<[IOSWorkspaceRoute]> {
        Binding(
            get: { navigation.path },
            set: { value in
                if let departure = navigation.editorDeparture(for: value) {
                    let originalPath = navigation.path
                    let session = store.currentDocumentSessionToken
                    let account = store.snapshotSyncV2AccountScope
                    Task {
                        guard await store.flushDeviceSyncBeforeNavigationDeparture(departure),
                              navigation.path == originalPath,
                              store.currentDocumentSessionToken == session,
                              store.snapshotSyncV2AccountScope == account else { return }
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
        case let .projectHome(session):
            IOSProjectHomeView(
                store: store,
                openWriting: { navigation.showWriting(for: session) },
                openProjectInfo: { navigation.showProjectInfo(for: session) },
                openPlot: { navigation.showPlot(for: session) },
                openCharacters: { navigation.showCharacters(for: session) },
                openWorldbuilding: { navigation.showWorldbuilding(for: session) },
                openFeedback: { navigation.showFeedback(for: session) },
                openReferences: { navigation.showReferences(for: session) },
                openSettings: { navigation.showSettings(for: session) }
            )
        case .projectInfo: IOSProjectInfoView(store: store)
        case let .writing(session):
            IOSAdaptiveWritingView(store: store) { chapterID, episodeID in
                Task { @MainActor in
                    guard await store.selectEpisodeAfterDeviceSyncDeparture(
                        chapterID: chapterID,
                        episodeID: episodeID
                    ),
                        store.currentDocumentSessionToken == session else { return }
                    navigation.showEditor(
                        for: session,
                        chapterID: chapterID,
                        episodeID: episodeID
                    )
                }
            }
        case .plot: IOSPlotFeatureView(store: store)
        case .characters: IOSCharacterFeatureView(store: store)
        case .worldbuilding: IOSWorldbuildingFeatureView(store: store)
        case .feedback: IOSAssistantFeedbackView(store: store)
        case .references: IOSReferencesFeatureView(store: store)
        case .settings: IOSSettingsView(store: store, userDefaults: store.userDefaults)
        case .editor: IOSEditorPane(store: store, userDefaults: store.userDefaults)
        }
    }

    private func openWork(_ id: WorkID) {
        Task { await navigation.openLibraryWork(id, using: store) }
    }

    private func makeNew() {
        Task {
            guard await store.makeNewDocument(),
                  let session = store.currentDocumentSessionToken else { return }
            navigation.showProjectHome(for: session)
        }
    }
}

struct IOSEditorPane: View {
    @State private var showingAssistant = false
    let store: IOSDocumentStore
    let userDefaults: UserDefaults
    @AppStorage(IOSEditorFontPreference.preferenceKey)
    private var editorFontFamilyRawValue = IOSEditorFontPreference.initialRawValue

    init(store: IOSDocumentStore, userDefaults: UserDefaults) {
        self.store = store
        self.userDefaults = userDefaults
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
            VStack(spacing: 0) {
                if store.syncV2KeepBothPendingWorkID != nil {
                    Label(
                        "両方を残す処理中です。作品の切替が完了するまで本文を編集できません。",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                EditorView(
                    chapterKey: IOSEditorContentKey(
                        documentSession: editingToken.documentSession,
                        episodeID: episode.id,
                        editorContentGeneration: editingToken.editorContentGeneration
                    ),
                    initialText: episode.content,
                    selectionRequest: store.currentWorkTextSelectionRequest,
                    commandSession: store.editorCommandSession,
                    selectionContextMenuCommands: [
                        EditorSelectionContextMenuCommand(title: "選択範囲をコピー", systemImageName: "doc.on.clipboard") { snapshot in
                            guard store.currentEpisodeEditingToken == editingToken else { return }
                            store.copySelectionManuscript(text: snapshot.text, expectedEpisodeID: episode.id)
                        }
                    ],
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
                .disabled(store.syncV2KeepBothPendingWorkID != nil)
                IOSEditorAccessoryBar(
                    commandSession: store.editorCommandSession,
                    isEnabled: store.syncV2KeepBothPendingWorkID == nil
                )
                .id(editingToken)
            }
            .navigationTitle(episode.title)
            .modifier(IOSEpisodeRenameModifier(store: store, chapterID: chapter.id, episode: episode, titleMenu: true))
            .toolbar {
                IOSExplicitSyncButton(store: store)
                Button {
                    showingAssistant.toggle()
                } label: {
                    Label("AI", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(FuminiwaColor.accent.color)
                }
                .accessibilityLabel("AI支援")
                .accessibilityValue(showingAssistant ? "開いています" : "閉じています")
                .accessibilityIdentifier("ios.editor.assistant")
                Menu("コピー", systemImage: "doc.on.clipboard") {
                    Button("この話をコピー") { store.copyEpisodeManuscript(expectedEpisodeID: episode.id) }
                    Button("この章をコピー") { store.copyChapterManuscript(expectedChapterID: chapter.id) }
                }
            }
            .inspector(isPresented: $showingAssistant) {
                let account = store.snapshotSyncV2AccountScope
                let session = store.currentDocumentSessionToken
                AssistantPanelView(
                    defaults: userDefaults,
                    contextID: "\(editingToken)-\(account)",
                    episodeTitle: episode.title,
                    currentEpisodeID: episode.id,
                    capture: {
                        guard store.currentEpisodeEditingToken == editingToken,
                              store.snapshotSyncV2AccountScope == account,
                              !store.isDocumentTransitionInProgress,
                              !store.syncV2AccountTransitionInProgress,
                              store.syncV2KeepBothPendingWorkID == nil else { throw AssistantError.emptyContent }
                        switch store.editorCommandSession.captureActiveCommittedText() {
                        case let .captured(text): return AssistantManuscript(title: episode.title, content: text)
                        case .compositionInProgress: throw AssistantError.composing
                        case .notActive: return AssistantManuscript(title: episode.title, content: store.selectedEpisode?.content ?? "")
                        }
                    }, close: { showingAssistant = false },
                    applyProofreading: { manuscript, replacement in
                        store.applyAssistantProofreading(manuscript, replacement: replacement,
                                                         editingToken: editingToken, account: account)
                    },
                    saveFeedback: { feedback in
                        guard store.currentEpisodeEditingToken == editingToken,
                              store.snapshotSyncV2AccountScope == account,
                              let session else { return false }
                        return await store.saveAssistantFeedback(feedback, session: session,
                                                                 account: account)
                    },
                    writingHost: store.writingAssistantHost,
                    chapters: store.document.chapters,
                    captureScope: { scope in
                        guard store.currentEpisodeEditingToken == editingToken,
                              store.snapshotSyncV2AccountScope == account,
                              !store.isDocumentTransitionInProgress,
                              !store.syncV2AccountTransitionInProgress,
                              store.syncV2KeepBothPendingWorkID == nil else { throw AssistantError.emptyContent }
                        return try scope.capture(chapters: store.document.chapters, currentID: episode.id) {
                            guard let selected = store.selectedEpisode else { throw AssistantError.emptyContent }
                            switch store.editorCommandSession.captureActiveCommittedText() {
                            case let .captured(text): return AssistantManuscript(title: selected.title, content: text)
                            case .compositionInProgress: throw AssistantError.composing
                            case .notActive: return AssistantManuscript(title: selected.title, content: selected.content)
                            }
                        }
                    }
                )
            }
        } else {
            ContentUnavailableView("話を選択してください", systemImage: "doc.text")
        }
    }
}
