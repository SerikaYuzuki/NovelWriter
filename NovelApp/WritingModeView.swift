import AppKit
import EditorKit
import NovelCore
import NovelUI
import SwiftUI

struct WritingModeView: View {
    @Binding var searchSelectionRequest: EditorSelectionRequest?
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    var body: some View {
        HSplitView {
            OutlineContainerView()
                .frame(minWidth: 224, idealWidth: 360, maxWidth: 440)

            EditorPaneView(
                searchSelectionRequest: $searchSelectionRequest,
                onOpenCharacter: onOpenCharacter,
                onOpenPlotCard: onOpenPlotCard
            )
            .frame(minWidth: 560)
        }
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
        .focusable()
        .background {
            Button("検索") {
                appState.outlinePresentation.isSearchVisible = true
                appState.outlinePresentation.pinnedSearchByKeyboard = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
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
                chapter.content.localizedStandardContains(query)
        }
    }

    private var selectionBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selection },
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
            help: "文字数: \(ManuscriptMetrics.countCharacters(in: chapter.content))字"
        )
        metadataIcon(
            systemName: appState.saveState.systemImage,
            help: "保存状態: \(appState.saveState.label)"
        )
        metadataIcon(
            systemName: chapter.memo.isEmpty ? "note.text" : "note.text.badge.plus",
            help: chapter.memo.isEmpty ? "章メモ: なし" : "章メモ: あり"
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

    @Binding var searchSelectionRequest: EditorSelectionRequest?
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    @State private var searchQuery = ""
    @State private var isSearchPresented = false
    @State private var lastSearchChapterID: ChapterID?
    @State private var lastSearchQuery = ""
    @State private var lastSearchRange: NSRange?
    @State private var didMissSearch = false
    @State private var isMemoPresented = false

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBarView(
                isSearchPresented: $isSearchPresented,
                isMemoPresented: $isMemoPresented,
                onOpenCharacter: onOpenCharacter,
                onOpenPlotCard: onOpenPlotCard
            )

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
                    Color(hex: editorSettings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor)
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
            } else {
                ContentUnavailableView(
                    "章が選択されていません",
                    systemImage: "doc.text",
                    description: Text("Outlineから章を選択するか、章を追加してください。")
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
        .onChange(of: appState.selection) { _, newSelection in
            if lastSearchChapterID != newSelection {
                resetSearchCursor()
            }
        }
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
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

private struct EditorTopBarView: View {
    @Environment(AppState.self) private var appState

    @Binding var isSearchPresented: Bool
    @Binding var isMemoPresented: Bool
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    @State private var snapshots: [DocumentSnapshotInfo] = []
    @State private var snapshotPendingRestore: DocumentSnapshotInfo?
    @State private var restoreErrorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.selectedChapter?.title ?? "章未選択")
                    .font(.headline)
                    .lineLimit(1)
                Label(appState.saveState.label, systemImage: appState.saveState.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isSearchPresented = true
            } label: {
                Label("検索", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help("検索")

            Button {
                isMemoPresented.toggle()
            } label: {
                Label("章メモ", systemImage: "note.text")
            }
            .labelStyle(.iconOnly)
            .help("章メモ")
            .popover(isPresented: $isMemoPresented) {
                ChapterMemoPopover()
                    .frame(width: 320, height: 260)
            }

            Menu {
                Button("スナップショットを保存") {
                    Task {
                        _ = await appState.createSnapshot()
                        await refreshSnapshots()
                    }
                }

                Divider()

                if snapshots.isEmpty {
                    Text("スナップショットはありません")
                } else {
                    ForEach(snapshots) { snapshot in
                        Menu(snapshot.displayName) {
                            Button("この状態に戻す…") {
                                snapshotPendingRestore = snapshot
                            }
                            Button("Finder で表示") {
                                NSWorkspace.shared.activateFileViewerSelecting([snapshot.url])
                            }
                        }
                    }
                }
            } label: {
                topBarIcon("clock.arrow.circlepath", help: "履歴")
            }
            .menuStyle(.borderlessButton)

            Button {} label: {
                Label("プレビュー", systemImage: "doc.richtext")
            }
            .labelStyle(.iconOnly)
            .help("プレビュー")
            .disabled(true)

            Menu {
                ChapterContextMenuContent(
                    onOpenCharacter: onOpenCharacter,
                    onOpenPlotCard: onOpenPlotCard
                )
            } label: {
                topBarIcon("doc.text.magnifyingglass", help: "この章")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task(id: appState.documentURL) {
            await refreshSnapshots()
        }
        .confirmationDialog(
            "このスナップショットに戻しますか？",
            isPresented: restoreDialogIsPresented,
            presenting: snapshotPendingRestore
        ) { snapshot in
            Button("戻す", role: .destructive) {
                Task {
                    let success = await appState.restoreSnapshot(at: snapshot.url)
                    await refreshSnapshots()
                    if !success {
                        restoreErrorMessage = "スナップショットを復元できませんでした。保存に失敗したか、ファイルにアクセスできない可能性があります。"
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { snapshot in
            Text("「\(snapshot.displayName)」の状態に戻します。いまの内容は先にスナップショットへ退避します。")
        }
        .alert(
            "復元できませんでした",
            isPresented: restoreErrorIsPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreErrorMessage ?? "")
        }
    }

    private var restoreDialogIsPresented: Binding<Bool> {
        Binding(
            get: { snapshotPendingRestore != nil },
            set: { isPresented in
                if !isPresented {
                    snapshotPendingRestore = nil
                }
            }
        )
    }

    private var restoreErrorIsPresented: Binding<Bool> {
        Binding(
            get: { restoreErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    restoreErrorMessage = nil
                }
            }
        )
    }

    private func refreshSnapshots() async {
        snapshots = await appState.listSnapshots()
    }

    private func topBarIcon(_ systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
            .help(help)
    }
}

private struct ChapterMemoPopover: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("章メモ")
                .font(.headline)
            TextEditor(text: memoBinding)
        }
        .padding(12)
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { appState.selectedChapter?.memo ?? "" },
            set: { appState.updateSelectedChapterMemo($0) }
        )
    }
}

private struct ChapterContextMenuContent: View {
    @Environment(AppState.self) private var appState

    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    var body: some View {
        Section("プロットカード") {
            if chapterPlotCards.isEmpty {
                Text("プロットカードがありません")
            } else {
                ForEach(chapterPlotCards) { card in
                    Button(NovelDocument.normalizedPlotCardTitle(card.title)) {
                        onOpenPlotCard(card.id)
                    }
                }
            }
        }

        Section("登場人物") {
            if appearingCharacters.isEmpty {
                Text("登場人物がありません")
            } else {
                ForEach(appearingCharacters) { character in
                    Button(NovelDocument.normalizedCharacterName(character.name)) {
                        onOpenCharacter(character.id)
                    }
                }
            }
        }
    }

    private var chapterPlotCards: [PlotCard] {
        guard let chapterID = appState.selection else { return [] }
        return appState.document.plotCards.filter { $0.chapterID == chapterID }
    }

    private var appearingCharacters: [NovelCore.Character] {
        guard let chapter = appState.selectedChapter else { return [] }
        return appState.document.characters.filter { character in
            CharacterAppearanceDetector.appearances(
                for: character,
                in: NovelDocument(
                    id: appState.document.id,
                    title: appState.document.title,
                    chapters: [chapter],
                    characters: [],
                    plotCards: [],
                    flags: []
                )
            ).isEmpty == false
        }
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
