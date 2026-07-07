import EditorKit
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
/// 章タイトル編集・章削除は Phase 3 で追加する(ここでは実装しない)。
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                ForEach(appState.document.chapters) { chapter in
                    Text(chapter.title)
                        .tag(chapter.id)
                }
                .onMove { offsets, destination in
                    appState.moveChapters(fromOffsets: offsets, toOffset: destination)
                }
            }
            .navigationTitle(appState.document.title)
            .toolbar {
                ToolbarItem {
                    Button {
                        appState.addChapter()
                    } label: {
                        Label("章を追加", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let chapter = appState.selectedChapter {
                EditorView(
                    chapterKey: chapter.id,
                    initialText: chapter.content,
                    onTextChange: { newText in
                        appState.updateSelectedChapterContent(newText)
                    }
                )
            } else {
                ContentUnavailableView(
                    "章が選択されていません",
                    systemImage: "doc.text",
                    description: Text("左のサイドバーから章を選択するか、章を追加してください。")
                )
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
}

#Preview {
    ContentView()
        .environment(AppState(dependencies: AppDependencies()))
}
