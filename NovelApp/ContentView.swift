import EditorKit
import Foundation
import NovelCore
import SwiftUI

/// 画面構成を担当する(docs/DESIGN.md 5.3)。
///
/// ```text
/// NavigationSplitView
/// ├── Sidebar: 章リスト
/// └── Detail: EditorView
/// ```
///
struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var chapterPendingDeletion: Chapter?
    @State private var searchQuery = ""
    @State private var searchSelectionRequest: EditorSelectionRequest?
    @State private var lastSearchChapterID: ChapterID?
    @State private var lastSearchQuery = ""
    @State private var lastSearchRange: NSRange?
    @State private var didMissSearch = false
    @State private var isInspectorPresented = true
    @State private var inspectorTab: InspectorTab = .memo
    @State private var operationMessage: OperationMessage?

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                ForEach(appState.document.chapters) { chapter in
                    HStack(spacing: 6) {
                        ChapterTitleField(
                            chapter: chapter,
                            onTitleChange: { title in
                                appState.updateChapterTitle(title, for: chapter.id)
                            },
                            onCommit: {
                                appState.commitChapterTitleEditing()
                            }
                        )

                        if !chapter.memo.isEmpty {
                            Image(systemName: "note.text")
                                .foregroundStyle(.secondary)
                                .help("メモあり")
                        }
                    }
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
            .navigationTitle(appState.document.title)
            .toolbar {
                ToolbarItemGroup {
                    SearchToolbarItems(
                        query: $searchQuery,
                        didMissSearch: didMissSearch,
                        isChapterSelected: appState.selectedChapter != nil,
                        onQueryChanged: { newQuery in
                            if lastSearchQuery != newQuery {
                                resetSearchCursor()
                            }
                        },
                        onPrevious: {
                            jumpToSearchResult(direction: .backward)
                        },
                        onNext: {
                            jumpToSearchResult(direction: .forward)
                        }
                    )

                    Button {
                        Task { await createSnapshot() }
                    } label: {
                        Label("スナップショットを保存", systemImage: "camera")
                    }

                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Label("インスペクタ", systemImage: "sidebar.right")
                    }

                    Button(role: .destructive) {
                        if let chapter = appState.selectedChapter {
                            chapterPendingDeletion = chapter
                        }
                    } label: {
                        Label("章を削除", systemImage: "trash")
                    }
                    .disabled(appState.selectedChapter == nil || appState.document.chapters.count <= 1)

                    Button {
                        appState.addChapter()
                    } label: {
                        Label("章を追加", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let chapter = appState.selectedChapter {
                VStack(spacing: 0) {
                    EditorView(
                        chapterKey: chapter.id,
                        initialText: chapter.content,
                        selectionRequest: searchSelectionRequest,
                        onTextChange: { newText in
                            appState.updateSelectedChapterContent(newText)
                        }
                    )

                    ManuscriptStatusBar(
                        chapterCharacterCount: ManuscriptMetrics.countCharacters(in: chapter.content),
                        totalCharacterCount: appState.document.manuscriptCharacterCount
                    )
                }
            } else {
                ContentUnavailableView(
                    "章が選択されていません",
                    systemImage: "doc.text",
                    description: Text("左のサイドバーから章を選択するか、章を追加してください。")
                )
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            InspectorView(
                selectedChapter: appState.selectedChapter,
                memo: selectedChapterMemoBinding,
                selectedTab: $inspectorTab,
                onCharacterSearch: { query in
                    beginSearch(query: query)
                },
                onCharacterAppearanceJump: { appearance in
                    jumpToCharacterAppearance(appearance)
                },
                onPlotChapterJump: { chapterID in
                    appState.selectChapter(chapterID)
                },
                onFlagChapterJump: { chapterID in
                    appState.selectChapter(chapterID)
                }
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
        .alert(item: $operationMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("OK")))
        }
        .onChange(of: appState.selection) { _, newSelection in
            if lastSearchChapterID != newSelection {
                resetSearchCursor()
            }
        }
    }

    /// `List(selection:)` に渡すためのバインディング。
    /// 単純な双方向バインディングではなく、選択変更を `AppState.selectChapter(_:)`
    /// に委譲することで、章切り替え時の即時保存(docs/DESIGN.md 6.4)をトリガーする。
    private var selectionBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selection },
            set: { appState.selectChapter($0) }
        )
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
            get: {
                appState.selectedChapter?.memo ?? ""
            },
            set: { memo in
                appState.updateSelectedChapterMemo(memo)
            }
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

        guard let range = TextSearch.find(
            query: searchQuery,
            in: chapter.content,
            from: startLocation,
            direction: direction
        ) else {
            didMissSearch = true
            return
        }

        didMissSearch = false
        lastSearchChapterID = chapter.id
        lastSearchQuery = searchQuery
        lastSearchRange = range
        searchSelectionRequest = EditorSelectionRequest(range: range)
    }

    private func beginSearch(query: String) {
        searchQuery = query
        resetSearchCursor()
        jumpToSearchResult(direction: .forward)
    }

    private func jumpToCharacterAppearance(_ appearance: CharacterAppearance) {
        searchQuery = appearance.query
        didMissSearch = false
        lastSearchChapterID = appearance.chapterID
        lastSearchQuery = appearance.query
        lastSearchRange = appearance.range
        appState.selectChapter(appearance.chapterID)
        searchSelectionRequest = EditorSelectionRequest(range: appearance.range)
    }

    private func resetSearchCursor() {
        didMissSearch = false
        lastSearchChapterID = nil
        lastSearchQuery = ""
        lastSearchRange = nil
        // 章が切り替わったときに、古いジャンプ要求が残らないようにする。
        // `EditorView` の Coordinator が新しい章向けに作り直された場合、
        // 作り直し前の `searchSelectionRequest` がそのまま残っていると、
        // 新しい章に過去のジャンプが誤って再適用されてしまう。
        searchSelectionRequest = nil
    }

    @MainActor
    private func createSnapshot() async {
        if let url = await appState.createSnapshot() {
            operationMessage = OperationMessage(title: "保存しました", body: url.lastPathComponent)
        } else {
            operationMessage = OperationMessage(title: "保存できませんでした", body: "スナップショット保存に失敗しました。")
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState(dependencies: AppDependencies()))
}
