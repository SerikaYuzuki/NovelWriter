import NovelCore
import SwiftUI

@MainActor
struct IOSWritingEditorIdentityBoundary {
    let store: IOSDocumentStore

    @discardableResult
    func perform(_ operation: () -> Void) -> Bool {
        let departure = IOSWorkspaceEditorDeparture(
            documentID: IOSPrivateDocumentID(
                packageName: store.documentURL.lastPathComponent
            ),
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

struct IOSAdaptiveWritingView: View {
    let store: IOSDocumentStore
    let openEpisode: (ChapterID, EpisodeID) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var regularProjectSection: IOSRegularProjectSection? = .writing
    @State private var presentedHorizontalSizeClass: UserInterfaceSizeClass?

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
            presentedHorizontalSizeClass = IOSAdaptiveWritingLayoutTransition.nextSizeClass(
                from: currentSizeClass,
                to: newSizeClass
            ) {
                IOSWritingEditorIdentityBoundary(store: store).perform {}
            }
        }
    }

    private var effectiveHorizontalSizeClass: UserInterfaceSizeClass? {
        presentedHorizontalSizeClass ?? horizontalSizeClass
    }

    @ViewBuilder
    private var regularLayout: some View {
        switch regularProjectSection ?? .writing {
        case .writing:
            NavigationSplitView {
                regularProjectSidebar
            } content: {
                IOSWritingOutlineList(store: store) { chapterID, episodeID in
                    store.selectChapter(chapterID)
                    store.selectEpisode(episodeID)
                }
            } detail: {
                IOSEditorPane(store: store)
            }
            .navigationSplitViewStyle(.balanced)
            .navigationTitle("執筆")
        case .projectInfo:
            NavigationSplitView {
                regularProjectSidebar
            } detail: {
                IOSProjectInfoView(store: store)
            }
            .navigationSplitViewStyle(.balanced)
        case .appearance:
            NavigationSplitView {
                regularProjectSidebar
            } detail: {
                IOSAppearanceSettingsView()
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
                IOSWritingEditorIdentityBoundary(store: store).perform {
                    regularProjectSection = newSection
                }
            }
        )
    }
}

private enum IOSRegularProjectSection: Hashable {
    case writing
    case projectInfo
    case appearance
}

private struct IOSRegularProjectSidebar: View {
    let store: IOSDocumentStore
    @Binding var selection: IOSRegularProjectSection?

    var body: some View {
        List(selection: $selection) {
            Section("この作品") {
                Label("執筆", systemImage: "square.and.pencil")
                    .tag(IOSRegularProjectSection.writing)
                    .accessibilityIdentifier("ios.ipad.project.writing")

                Label("作品情報", systemImage: "doc.text.magnifyingglass")
                    .tag(IOSRegularProjectSection.projectInfo)
                    .accessibilityIdentifier("ios.ipad.project.info")
            }

            Section("アプリ") {
                Label("表示設定", systemImage: "circle.lefthalf.filled")
                    .tag(IOSRegularProjectSection.appearance)
                    .accessibilityIdentifier("ios.ipad.project.appearance")
            }

            Section("共有") {
                Button {
                    editorIdentityBoundary.perform {
                        Task {
                            await store.requestExport()
                        }
                    }
                } label: {
                    Label("作品を書き出す…", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("現在の作業コピーから、共有用のnovelpkgファイルを作ります。")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.thinMaterial)
        .navigationTitle(displayTitle)
    }

    private var displayTitle: String {
        let title = store.document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "名称未設定の作品" : title
    }

    private var editorIdentityBoundary: IOSWritingEditorIdentityBoundary {
        IOSWritingEditorIdentityBoundary(store: store)
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
                            editorIdentityBoundary.perform {
                                openEpisode(chapter.id, episode.id)
                            }
                        } label: {
                            IOSEpisodeOutlineRow(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ios.outline.episode.\(episode.id)")
                    }
                    .onDelete { offsets in
                        editorIdentityBoundary.perform {
                            store.deleteEpisodes(at: offsets, chapterID: chapter.id)
                        }
                    }
                    .onMove { offsets, destination in
                        store.moveEpisodes(
                            in: chapter.id,
                            fromOffsets: offsets,
                            toOffset: destination
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        TextField("章タイトル", text: chapterTitle(chapter.id))
                            .font(.headline)
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("章タイトル")

                        Spacer(minLength: 8)

                        Button {
                            editorIdentityBoundary.perform {
                                store.selectChapter(chapter.id)
                                store.addEpisode()
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
                store.moveChapters(fromOffsets: offsets, toOffset: destination)
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
                        editorIdentityBoundary.perform {
                            store.addChapter()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorIdentityBoundary.perform {
                        store.addChapter()
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
