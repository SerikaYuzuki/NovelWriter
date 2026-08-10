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
        .onChange(of: currentDocumentID) { _, _ in
            synchronizeNavigationWithStore()
        }
    }

    @ViewBuilder
    private func destination(for route: IOSWorkspaceRoute) -> some View {
        if currentDocumentID == route.documentID {
            switch route {
            case let .projectHome(documentID):
                IOSProjectHomeView(
                    store: store,
                    openWriting: {
                        navigation.showWriting(for: documentID)
                    },
                    openProjectInfo: {
                        navigation.showProjectInfo(for: documentID)
                    }
                )
            case .projectInfo:
                IOSProjectInfoView(store: store)
            case let .writing(documentID):
                IOSAdaptiveWritingView(store: store) { chapterID, episodeID in
                    store.selectChapter(chapterID)
                    store.selectEpisode(episodeID)
                    navigation.showEditor(
                        for: documentID,
                        chapterID: chapterID,
                        episodeID: episodeID
                    )
                }
            case let .editor(_, chapterID, episodeID):
                IOSEditorPane(store: store)
                    .onAppear {
                        store.selectChapter(chapterID)
                        store.selectEpisode(episodeID)
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

    private var workspacePath: Binding<[IOSWorkspaceRoute]> {
        Binding(
            get: { navigation.path },
            set: { newPath in
                navigation.updatePath(newPath) { departure in
                    IOSWorkspaceEditorSynchronizer.synchronize(
                        store: store,
                        departure: departure
                    )
                }
            }
        )
    }

    private var currentDocumentID: IOSPrivateDocumentID? {
        guard store.startupState == .ready else { return nil }
        return IOSPrivateDocumentID(packageName: store.documentURL.lastPathComponent)
    }

    private func synchronizeNavigationWithStore() {
        guard let currentDocumentID else { return }
        navigation.documentDidChange(to: currentDocumentID)
    }

    private func openDocument(_ id: IOSPrivateDocumentID) {
        Task {
            guard await store.openPrivateDocument(id: id) else { return }
            navigation.showProjectHome(for: id)
        }
    }

    private func makeNewDocument() {
        Task {
            guard await store.makeNewDocument() else { return }
            navigation.showProjectHome(
                for: IOSPrivateDocumentID(packageName: store.documentURL.lastPathComponent)
            )
        }
    }
}

struct IOSEditorPane: View {
    let store: IOSDocumentStore
    @State private var isMemoPresented = false
    @State private var searchQuery = ""
    @State private var searchCursor = 0
    @State private var selectionRequest: EditorSelectionRequest?
    @State private var mountedDocumentID: IOSPrivateDocumentID?
    @State private var mountedChapterID: ChapterID?
    @State private var mountedEpisodeID: EpisodeID?

    var body: some View {
        if let chapter = store.selectedChapter, let episode = store.selectedEpisode {
            VStack(spacing: 0) {
                HStack {
                    TextField("話タイトル", text: episodeTitle(chapter.id, episode.id))
                        .textFieldStyle(.plain)
                    Spacer()
                    Text("\(ManuscriptMetrics.countCharacters(in: episode.content))字")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                EditorView(
                    chapterKey: episode.id,
                    initialText: episode.content,
                    selectionRequest: selectionRequest,
                    commandSession: store.editorCommandSession,
                    selectionContextMenuCommands: selectionCommands(for: episode.id),
                    onTextChange: { text in
                        store.updateEpisodeContent(
                            text,
                            chapterID: chapter.id,
                            episodeID: episode.id
                        )
                    }
                )
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
            .onDisappear {
                synchronizeMountedEditorBeforeDeparture()
            }
            .toolbar {
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
                ToolbarItemGroup(placement: .bottomBar) {
                    IOSSaveStateLabel(state: store.saveState)
                    Spacer()
                    if !searchQuery.isEmpty {
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
        } else {
            ContentUnavailableView {
                Label("話を選択してください", systemImage: "doc.text")
            } description: {
                Text("章の話一覧から編集する本文を選びます。")
            } actions: {
                if store.selectedChapter != nil {
                    Button("話を追加") {
                        store.addEpisode()
                    }
                }
            }
        }
    }

    private func captureMountedEditorIdentity(
        chapterID: ChapterID,
        episodeID: EpisodeID
    ) {
        let currentDocumentID = IOSPrivateDocumentID(
            packageName: store.documentURL.lastPathComponent
        )
        if mountedDocumentID == nil {
            mountedDocumentID = currentDocumentID
        }
        guard mountedDocumentID == currentDocumentID else { return }
        mountedChapterID = chapterID
        mountedEpisodeID = episodeID
    }

    private func synchronizeMountedEditorBeforeDeparture() {
        guard let mountedDocumentID else { return }
        IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: IOSWorkspaceEditorDeparture(
                documentID: mountedDocumentID,
                chapterID: mountedChapterID,
                episodeID: mountedEpisodeID
            )
        )
    }

    private func episodeTitle(_ chapterID: ChapterID, _ episodeID: EpisodeID) -> Binding<String> {
        Binding(
            get: { store.document.episode(episodeID)?.episode.title ?? "" },
            set: { store.updateEpisodeTitle($0, chapterID: chapterID, episodeID: episodeID) }
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

private struct IOSSaveStateLabel: View {
    let state: IOSSaveState

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(state == .failed ? Color(uiColor: .systemRed) : Color.secondary)
    }

    private var title: String {
        switch state {
        case .saved:
            "保存済み"
        case .dirty:
            "未保存の変更"
        case .saving:
            "保存中"
        case .failed:
            "保存失敗"
        }
    }

    private var systemImage: String {
        switch state {
        case .saved:
            "checkmark.circle"
        case .dirty:
            "circle"
        case .saving:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle"
        }
    }
}
