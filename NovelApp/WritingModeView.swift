import AppKit
import EditorKit
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

struct WritingModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings

    @Binding var searchSelectionRequest: EditorSelectionRequest?
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    @State private var chapterPendingDeletion: Chapter?
    @State private var searchQuery = ""
    @State private var isSearchPresented = false
    @State private var lastSearchChapterID: ChapterID?
    @State private var lastSearchQuery = ""
    @State private var lastSearchRange: NSRange?
    @State private var didMissSearch = false
    @State private var isInspectorPresented = true
    @State private var inspectorTab: WritingInspectorTab = .memo

    var body: some View {
        NavigationSplitView {
            chapterList
                .navigationTitle(appState.document.title)
        } detail: {
            editorArea
        }
        .inspector(isPresented: $isInspectorPresented) {
            WritingInspectorView(
                selectedTab: $inspectorTab,
                memo: selectedChapterMemoBinding,
                onOpenCharacter: onOpenCharacter,
                onOpenPlotCard: onOpenPlotCard
            )
        }
        .confirmationDialog(
            "章を削除しますか？",
            isPresented: deletionDialogIsPresented,
            presenting: chapterPendingDeletion
        ) { chapter in
            Button("削除", role: .destructive) {
                appState.deleteChapter(id: chapter.id)
                resetSearchCursor()
            }
            Button("キャンセル", role: .cancel) {}
        } message: { chapter in
            Text("「\(chapter.title)」を削除します。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleWritingInspector)) { _ in
            isInspectorPresented.toggle()
        }
        .onChange(of: appState.selection) { _, newSelection in
            if lastSearchChapterID != newSelection {
                resetSearchCursor()
            }
        }
    }

    private var chapterList: some View {
        List(selection: selectionBinding) {
            ForEach(appState.document.chapters) { chapter in
                ChapterListRow(
                    chapter: chapter,
                    onTitleChange: { title in
                        appState.updateChapterTitle(title, for: chapter.id)
                    },
                    onCommit: {
                        appState.commitChapterTitleEditing()
                    }
                )
                .contextMenu {
                    Button(role: .destructive) {
                        chapterPendingDeletion = chapter
                    } label: {
                        Label("章を削除", systemImage: "trash")
                    }
                    .disabled(appState.document.chapters.count <= 1)
                }
                .tag(chapter.id)
            }
            .onMove { offsets, destination in
                appState.moveChapters(fromOffsets: offsets, toOffset: destination)
            }
        }
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            if isSearchPresented {
                SearchBar(
                    query: $searchQuery,
                    didMissSearch: didMissSearch,
                    onPrevious: { jumpToSearchResult(direction: .backward) },
                    onNext: { jumpToSearchResult(direction: .forward) },
                    onClose: {
                        isSearchPresented = false
                        resetSearchCursor()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let chapter = appState.selectedChapter {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    EditorView(
                        chapterKey: chapter.id,
                        initialText: chapter.content,
                        selectionRequest: searchSelectionRequest,
                        configuration: editorSettings.configuration,
                        onTextChange: { newText in
                            appState.updateSelectedChapterContent(newText)
                        }
                    )
                    .frame(maxWidth: editorMaximumWidth)
                }

                ManuscriptStatusBar(
                    chapterCharacterCount: ManuscriptMetrics.countCharacters(in: chapter.content),
                    totalCharacterCount: appState.document.manuscriptCharacterCount
                )
            } else {
                ContentUnavailableView(
                    "章が選択されていません",
                    systemImage: "doc.text",
                    description: Text("左のサイドバーから章を選択するか、章を追加してください。")
                )
            }
        }
        .animation(.snappy(duration: 0.18), value: isSearchPresented)
        .focusable()
        .background {
            Button("検索") {
                isSearchPresented = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onKeyPress(.escape) {
            guard isSearchPresented else { return .ignored }
            isSearchPresented = false
            return .handled
        }
    }

    private var selectionBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selection },
            set: { appState.selectChapter($0) }
        )
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { chapterPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    chapterPendingDeletion = nil
                }
            }
        )
    }

    private var selectedChapterMemoBinding: Binding<String> {
        Binding(
            get: { appState.selectedChapter?.memo ?? "" },
            set: { appState.updateSelectedChapterMemo($0) }
        )
    }

    private func jumpToSearchResult(direction: TextSearchDirection) {
        guard let chapter = appState.selectedChapter, !searchQuery.isEmpty else { return }

        let startLocation: Int = if lastSearchChapterID == chapter.id, lastSearchQuery == searchQuery, let lastSearchRange {
            switch direction {
            case .forward:
                lastSearchRange.location + lastSearchRange.length
            case .backward:
                lastSearchRange.location
            }
        } else {
            switch direction {
            case .forward:
                0
            case .backward:
                (chapter.content as NSString).length
            }
        }

        guard let range = TextSearch.find(query: searchQuery, in: chapter.content, from: startLocation, direction: direction) else {
            didMissSearch = true
            return
        }

        didMissSearch = false
        lastSearchChapterID = chapter.id
        lastSearchQuery = searchQuery
        lastSearchRange = range
        searchSelectionRequest = EditorSelectionRequest(range: range)
    }

    private func resetSearchCursor() {
        didMissSearch = false
        lastSearchChapterID = nil
        lastSearchQuery = ""
        lastSearchRange = nil
        searchSelectionRequest = nil
    }
}

private struct ChapterListRow: View {
    let chapter: Chapter
    let onTitleChange: (String) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChapterTitleField(chapter: chapter, onTitleChange: onTitleChange, onCommit: onCommit)
            HStack(spacing: 8) {
                Text("\(ManuscriptMetrics.countCharacters(in: chapter.content))字")
                if !chapter.memo.isEmpty {
                    Image(systemName: "note.text")
                        .help("メモあり")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct SearchBar: View {
    @Binding var query: String
    let didMissSearch: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("検索", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(onNext)
            Button(action: onPrevious) {
                Label("前の検索結果", systemImage: "chevron.up")
            }
            .disabled(query.isEmpty)
            Button(action: onNext) {
                Label("次の検索結果", systemImage: "chevron.down")
            }
            .disabled(query.isEmpty)
            if didMissSearch {
                Text("見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Label("閉じる", systemImage: "xmark")
            }
        }
        .labelStyle(.iconOnly)
        .padding(8)
        .background(.bar)
        .onAppear {
            isFocused = true
        }
    }
}

enum WritingInspectorTab: Hashable {
    case memo
    case chapter
    case attachments
}
