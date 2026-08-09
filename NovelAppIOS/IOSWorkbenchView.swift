import EditorKit
import NovelCore
import SwiftUI

struct IOSWorkbenchView: View {
    @Bindable var store: IOSDocumentStore

    var body: some View {
        NavigationSplitView {
            IOSChapterList(store: store)
        } content: {
            IOSEpisodeList(store: store)
        } detail: {
            IOSEditorPane(store: store)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct IOSChapterList: View {
    let store: IOSDocumentStore

    var body: some View {
        List(selection: chapterSelection) {
            Section("作品") {
                TextField("作品タイトル", text: documentTitle)
                    .textInputAutocapitalization(.never)
            }

            Section("章") {
                ForEach(store.document.chapters) { chapter in
                    Text(chapter.title.isEmpty ? "名称未設定の章" : chapter.title)
                        .tag(chapter.id)
                        .contextMenu {
                            Button("この章を選択") {
                                store.selectChapter(chapter.id)
                            }
                        }
                }
                .onMove { offsets, destination in
                    store.moveChapters(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .navigationTitle("ふみにわ")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Menu {
                    Button("新規作品") {
                        Task {
                            await store.makeNewDocument()
                        }
                    }
                    Button("Filesから取り込む") {
                        store.isImporterPresented = true
                    }
                    Button("作品を書き出す") {
                        Task {
                            await store.requestExport()
                        }
                    }
                } label: {
                    Label("作品", systemImage: "doc.badge.gearshape")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.addChapter()
                } label: {
                    Label("章を追加", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    private var chapterSelection: Binding<ChapterID?> {
        Binding(
            get: { store.selectedChapterID },
            set: { store.selectChapter($0) }
        )
    }

    private var documentTitle: Binding<String> {
        Binding(
            get: { store.document.title },
            set: { store.updateDocumentTitle($0) }
        )
    }
}

private struct IOSEpisodeList: View {
    let store: IOSDocumentStore

    var body: some View {
        if let chapter = store.selectedChapter {
            List(selection: episodeSelection) {
                Section {
                    TextField("章タイトル", text: chapterTitle(chapter.id))
                }

                Section("話") {
                    ForEach(chapter.episodes) { episode in
                        Text(episode.title.isEmpty ? "名称未設定の話" : episode.title)
                            .tag(episode.id)
                    }
                    .onDelete { offsets in
                        store.deleteEpisodes(at: offsets, chapterID: chapter.id)
                    }
                    .onMove { offsets, destination in
                        store.moveEpisodes(
                            in: chapter.id,
                            fromOffsets: offsets,
                            toOffset: destination
                        )
                    }
                }
            }
            .navigationTitle(chapter.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.addEpisode()
                    } label: {
                        Label("話を追加", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        } else {
            ContentUnavailableView(
                "章がありません",
                systemImage: "list.bullet.rectangle",
                description: Text("章を追加すると本文を書き始められます。")
            )
        }
    }

    private var episodeSelection: Binding<EpisodeID?> {
        Binding(
            get: { store.selectedEpisodeID },
            set: { store.selectEpisode($0) }
        )
    }

    private func chapterTitle(_ chapterID: ChapterID) -> Binding<String> {
        Binding(
            get: {
                store.document.chapters.first(where: { $0.id == chapterID })?.title ?? ""
            },
            set: { store.updateChapterTitle($0, chapterID: chapterID) }
        )
    }
}

private struct IOSEditorPane: View {
    let store: IOSDocumentStore
    @State private var isMemoPresented = false
    @State private var searchQuery = ""
    @State private var searchCursor = 0
    @State private var selectionRequest: EditorSelectionRequest?

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
                .padding(.vertical, 10)

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
            .foregroundStyle(state == .failed ? Color.red : Color.secondary)
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
