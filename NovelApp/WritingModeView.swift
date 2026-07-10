import AppKit
import EditorKit
import NovelCore
import NovelUI
import SwiftUI

struct WritingModeView: View {
    var body: some View {
        // Toolbar-1 以降、Outline は NavigationSplitView の content 列へ移した。
        // Toolbar-2 以降、上部 chrome は WorkbenchToolbarContent が所有する。
        EditorPaneView()
    }
}

struct OutlineContainerView: View {
    @Environment(AppState.self) private var appState

    @State private var chapterPendingDeletion: Chapter?

    var body: some View {
        VStack(spacing: 0) {
            if appState.outlinePresentation.isSearchVisible {
                OutlineSearchBar(
                    text: outlineSearchBinding,
                    onClose: {
                        appState.outlinePresentation.isSearchVisible = false
                        appState.outlinePresentation.pinnedSearchByKeyboard = false
                        appState.outlinePresentation.searchText = ""
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            OutlineView(chapterPendingDeletion: $chapterPendingDeletion)
        }
        .animation(.snappy(duration: 0.18), value: appState.outlinePresentation.isSearchVisible)
        .background(.bar)
        .focusedSceneValue(\.workbenchSearchSurface, .outline)
        .focusable()
        .onKeyPress(.escape) {
            guard appState.outlinePresentation.isSearchVisible else { return .ignored }
            appState.outlinePresentation.isSearchVisible = false
            appState.outlinePresentation.pinnedSearchByKeyboard = false
            appState.outlinePresentation.searchText = ""
            return .handled
        }
        .confirmationDialog(
            "章を削除しますか？",
            isPresented: deletionDialogIsPresented,
            presenting: chapterPendingDeletion
        ) { chapter in
            Button("削除", role: .destructive) {
                appState.deleteChapter(id: chapter.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { chapter in
            Text("「\(chapter.title)」を削除します。")
        }
    }

    private var outlineSearchBinding: Binding<String> {
        Binding(
            get: { appState.outlinePresentation.searchText },
            set: { appState.outlinePresentation.searchText = $0 }
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
}

struct OutlineView: View {
    @Environment(AppState.self) private var appState

    @Binding var chapterPendingDeletion: Chapter?

    var body: some View {
        List(selection: selectionBinding) {
            Section("原稿") {
                ForEach(filteredChapters) { chapter in
                    OutlineChapterRow(chapter: chapter)
                        .contextMenu {
                            Button {
                                appState.selectChapter(chapter.id)
                                NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
                            } label: {
                                Label("章メモ", systemImage: "note.text")
                            }

                            Menu {
                                ChapterContextMenuContent(
                                    appState: appState,
                                    chapterID: chapter.id,
                                    onOpenCharacter: { characterID in
                                        appState.selectCharacter(characterID)
                                        appState.selectProjectSection(.characters)
                                    },
                                    onOpenPlotCard: { cardID in
                                        appState.selectPlotCard(cardID)
                                        appState.selectProjectSection(.plot)
                                    }
                                )
                            } label: {
                                Label("この章", systemImage: "doc.text.magnifyingglass")
                            }

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
                    guard appState.outlinePresentation.searchText.isEmpty else { return }
                    appState.moveChapters(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if filteredChapters.isEmpty {
                ContentUnavailableView(
                    "章がありません",
                    systemImage: "doc.text",
                    description: Text("ツールバーの章を追加から章を追加できます。")
                )
            }
        }
        .background {
            OutlineScrollSearchTrigger(
                onScrollUp: {
                    guard !appState.outlinePresentation.pinnedSearchByKeyboard else { return }
                    appState.outlinePresentation.isSearchVisible = true
                },
                onScrollDown: {
                    guard !appState.outlinePresentation.pinnedSearchByKeyboard else { return }
                    guard appState.outlinePresentation.searchText.isEmpty else { return }
                    appState.outlinePresentation.isSearchVisible = false
                }
            )
        }
    }

    private var filteredChapters: [Chapter] {
        let query = appState.outlinePresentation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.document.chapters }
        return appState.document.chapters.filter { chapter in
            chapter.title.localizedStandardContains(query) ||
                chapter.episodes.contains { episode in
                    episode.title.localizedStandardContains(query) ||
                        episode.content.localizedStandardContains(query) ||
                        episode.memo.localizedStandardContains(query)
                }
        }
    }

    private var selectionBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selectedChapterID },
            set: { appState.selectChapter($0) }
        )
    }
}

private struct OutlineScrollSearchTrigger: NSViewRepresentable {
    let onScrollUp: () -> Void
    let onScrollDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onScrollUp = onScrollUp
        context.coordinator.onScrollDown = onScrollDown
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollUp: onScrollUp, onScrollDown: onScrollDown)
    }

    final class Coordinator: @unchecked Sendable {
        weak var view: NSView?
        var onScrollUp: () -> Void
        var onScrollDown: () -> Void

        private var monitor: Any?

        init(onScrollUp: @escaping () -> Void, onScrollDown: @escaping () -> Void) {
            self.onScrollUp = onScrollUp
            self.onScrollDown = onScrollDown
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let scrollingDeltaY = event.scrollingDeltaY
                MainActor.assumeIsolated {
                    self?.handle(scrollingDeltaY: scrollingDeltaY)
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        @MainActor
        private func handle(scrollingDeltaY: CGFloat) {
            guard isPointerInsideView else { return }
            if scrollingDeltaY > 2 {
                onScrollUp()
            } else if scrollingDeltaY < -2 {
                onScrollDown()
            }
        }

        @MainActor
        private var isPointerInsideView: Bool {
            guard let view, let window = view.window else { return false }
            let location = window.mouseLocationOutsideOfEventStream
            let frameInWindow = view.convert(view.bounds, to: nil)
            return frameInWindow.contains(location)
        }
    }
}

private struct OutlineChapterRow: View {
    @Environment(AppState.self) private var appState

    let chapter: Chapter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChapterTitleField(
                chapter: chapter,
                onTitleChange: { title in
                    appState.updateChapterTitle(title, for: chapter.id)
                },
                onCommit: {
                    appState.commitChapterTitleEditing()
                }
            )
            .lineLimit(1)
            .truncationMode(.tail)

            HStack(spacing: 8) {
                outlineIconMetadata
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var outlineIconMetadata: some View {
        metadataIcon(
            systemName: "textformat.size",
            help: "文字数: \(chapter.episodes.reduce(0) { $0 + ManuscriptMetrics.countCharacters(in: $1.content) })字"
        )
        metadataIcon(
            systemName: appState.saveState.systemImage,
            help: "保存状態: \(appState.saveState.label)"
        )
        metadataIcon(
            systemName: chapter.episodes.allSatisfy({ $0.memo.isEmpty }) ? "note.text" : "note.text.badge.plus",
            help: chapter.episodes.allSatisfy({ $0.memo.isEmpty }) ? "話メモ: なし" : "話メモ: あり"
        )
    }

    private func metadataIcon(systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help(help)
    }
}

private struct OutlineSceneRow: View {
    let title: String
    let characterCount: Int
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            Spacer()
            Image(systemName: "textformat.size")
                .help("文字数: \(characterCount)字")
            Image(systemName: "checkmark.circle")
                .help("状態: \(status)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct OutlineSearchBar: View {
    @Binding var text: String
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Outlineを検索", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            Button(action: onClose) {
                Label("閉じる", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
        }
        .padding(8)
        .background(.bar)
        .onAppear {
            isFocused = true
        }
    }
}

struct EditorPaneView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorSearchSession.self) private var editorSearchSession

    var body: some View {
        Group {
            if let episode = appState.selectedEpisode {
                ZStack {
                    Color(hex: editorSettings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor)
                    EditorView(
                        chapterKey: episode.id,
                        initialText: episode.content,
                        selectionRequest: editorSearchSession.selectionRequest,
                        configuration: editorSettings.configuration,
                        onTextChange: { newText in
                            appState.updateSelectedEpisodeContent(newText)
                        }
                    )
                    .frame(maxWidth: editorMaximumWidth)
                }
            } else {
                ContentUnavailableView(
                    "話が選択されていません",
                    systemImage: "doc.text",
                    description: Text("Outlineから章を選択するか、話を追加してください。")
                )
            }
        }
        .focusedSceneValue(\.workbenchSearchSurface, .editor)
        .onChange(of: appState.selectedEpisodeID) { _, newSelection in
            editorSearchSession.handleEpisodeChange(newSelection)
        }
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
    }
}
