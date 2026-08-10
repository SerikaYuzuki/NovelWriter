import NovelCore
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
        guard IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: departure
        ) else {
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
    @State private var regularProjectSection: IOSRegularProjectSection? = .writing
    @State private var presentedHorizontalSizeClass: UserInterfaceSizeClass?
    @State private var selectedPlotItem: IOSPlotSelection?
    @State private var selectedCharacterID: CharacterID?
    @State private var selectedWorldNoteID: WorldNoteID?
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
                IOSWritingOutlineList(store: store, openEpisode: openEpisode)
            }
        }
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

    @ViewBuilder
    private var regularLayout: some View {
        switch regularProjectSection ?? .writing {
        case .projectInfo:
            NavigationSplitView {
                regularProjectSidebar
            } detail: {
                IOSProjectInfoView(store: store)
            }
            .navigationSplitViewStyle(.balanced)
        case .writing:
            NavigationSplitView {
                regularProjectSidebar
            } content: {
                IOSWritingOutlineList(store: store) { chapterID, episodeID in
                    Task {
                        await store.selectEpisodeAfterDeviceSyncDeparture(
                            chapterID: chapterID,
                            episodeID: episodeID
                        )
                    }
                }
            } detail: {
                IOSEditorPane(store: store)
            }
            .navigationSplitViewStyle(.balanced)
            .navigationTitle("執筆")
        case .plot:
            NavigationSplitView {
                regularProjectSidebar
            } content: {
                IOSPlotOutlineView(
                    store: store,
                    selection: $selectedPlotItem,
                    expectedSession: expectedSession,
                    usesNavigationLinks: false
                )
            } detail: {
                IOSPlotDetailView(
                    store: store,
                    selection: selectedPlotItem,
                    expectedSession: expectedSession,
                    onDeletion: { selectedPlotItem = nil }
                )
            }
            .navigationSplitViewStyle(.balanced)
        case .characters:
            NavigationSplitView {
                regularProjectSidebar
            } content: {
                IOSCharacterOutlineView(
                    store: store,
                    selection: $selectedCharacterID,
                    expectedSession: expectedSession,
                    usesNavigationLinks: false
                )
            } detail: {
                IOSCharacterDetailView(
                    store: store,
                    characterID: selectedCharacterID,
                    expectedSession: expectedSession,
                    onDeletion: { selectedCharacterID = nil }
                )
            }
            .navigationSplitViewStyle(.balanced)
        case .worldbuilding:
            NavigationSplitView {
                regularProjectSidebar
            } content: {
                IOSWorldNoteOutlineView(
                    store: store,
                    selection: $selectedWorldNoteID,
                    expectedSession: expectedSession,
                    usesNavigationLinks: false
                )
            } detail: {
                IOSWorldNoteDetailView(
                    store: store,
                    noteID: selectedWorldNoteID,
                    expectedSession: expectedSession,
                    onDeletion: { selectedWorldNoteID = nil }
                )
            }
            .navigationSplitViewStyle(.balanced)
        case .references:
            NavigationSplitView {
                regularProjectSidebar
            } content: {
                IOSReferencesOutlineView(
                    store: store,
                    selection: $selectedReferenceFileName,
                    expectedSession: expectedSession,
                    usesNavigationLinks: false
                )
            } detail: {
                IOSReferenceDetailView(
                    store: store,
                    fileName: selectedReferenceFileName,
                    expectedSession: expectedSession,
                    onDeletion: { selectedReferenceFileName = nil }
                )
            }
            .navigationSplitViewStyle(.balanced)
        case .settings:
            NavigationSplitView {
                regularProjectSidebar
            } detail: {
                IOSSettingsView(store: store)
            }
            .navigationSplitViewStyle(.balanced)
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
}

private struct IOSWritingOutlineList: View {
    let store: IOSDocumentStore
    let openEpisode: (ChapterID, EpisodeID) -> Void

    var body: some View {
        List {
            ForEach(store.document.chapters) { chapter in
                Section {
                    ForEach(chapter.episodes) { episode in
                        Button {
                            openEpisode(chapter.id, episode.id)
                        } label: {
                            IOSEpisodeOutlineRow(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ios.outline.episode.\(episode.id)")
                    }
                    .onDelete { offsets in
                        Task {
                            await store.deleteEpisodesAfterDeviceSyncDeparture(
                                at: offsets,
                                chapterID: chapter.id
                            )
                        }
                    }
                    .onMove { offsets, destination in
                        Task {
                            await store.moveEpisodesAfterDeviceSyncDeparture(
                                in: chapter.id,
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        TextField("章タイトル", text: chapterTitle(chapter.id))
                            .font(.headline)
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("章タイトル")

                        Spacer(minLength: 8)

                        Button {
                            Task {
                                await store.addEpisodeAfterDeviceSyncDeparture(to: chapter.id)
                            }
                        } label: {
                            Label("話を追加", systemImage: "plus")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("「\(chapterDisplayTitle(chapter))」に話を追加")
                        .accessibilityIdentifier("ios.outline.chapter.\(chapter.id).addEpisode")
                    }
                }
            }
            .onMove { offsets, destination in
                Task {
                    await store.moveChaptersAfterDeviceSyncDeparture(
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
                            await store.addChapterAfterDeviceSyncDeparture()
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
                        await store.addChapterAfterDeviceSyncDeparture()
                    }
                } label: {
                    Label("章を追加", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .modifier(IOSWritingOutlineSurfaceModifier())
    }

    private var editorIdentityBoundary: IOSWritingEditorIdentityBoundary {
        IOSWritingEditorIdentityBoundary(store: store)
    }

    private func chapterTitle(_ chapterID: ChapterID) -> Binding<String> {
        Binding(
            get: {
                store.document.chapters.first(where: { $0.id == chapterID })?.title ?? ""
            },
            set: { store.updateChapterTitle($0, chapterID: chapterID) }
        )
    }

    private func chapterDisplayTitle(_ chapter: Chapter) -> String {
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
                .foregroundStyle(IOSPalette.accent)
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
