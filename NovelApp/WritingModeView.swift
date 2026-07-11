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
    @State private var episodePendingDeletion: EpisodeDeletionRequest?

    var body: some View {
        VStack(spacing: 0) {
            WritingOutlineHeader()

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

            OutlineView(
                chapterPendingDeletion: $chapterPendingDeletion,
                episodePendingDeletion: $episodePendingDeletion
            )
        }
        .animation(.snappy(duration: 0.18), value: appState.outlinePresentation.isSearchVisible)
        .workbenchGlassChromeStyle()
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
        .confirmationDialog(
            "話を削除しますか？",
            isPresented: episodeDeletionDialogIsPresented,
            presenting: episodePendingDeletion
        ) { request in
            Button("削除", role: .destructive) {
                _ = appState.deleteEpisode(id: request.episode.id, from: request.chapterID)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.episode.title)」を削除します。")
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

    private var episodeDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { episodePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    episodePendingDeletion = nil
                }
            }
        )
    }
}

private struct WritingOutlineHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Spacer()
            Button {
                appState.addChapter()
            } label: {
                Label("章を追加", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("章を追加")
        }
        .padding(8)
    }
}

struct EpisodeDeletionRequest: Identifiable {
    let episode: Episode
    let chapterID: ChapterID

    var id: EpisodeID {
        episode.id
    }
}

struct OutlineView: View {
    @Environment(AppState.self) private var appState

    @Binding var chapterPendingDeletion: Chapter?
    @Binding var episodePendingDeletion: EpisodeDeletionRequest?

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
                                Label("話メモ", systemImage: "note.text")
                            }
                            .disabled(chapter.episodes.isEmpty)

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
                        .tag(WritingOutlineSelection.chapter(chapter.id))

                    ForEach(filteredEpisodes(in: chapter)) { episode in
                        OutlineEpisodeRow(episode: episode, chapterID: chapter.id)
                            .contextMenu {
                                Button {
                                    appState.selectEpisode(episode.id, in: chapter.id)
                                    NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
                                } label: {
                                    Label("話メモ", systemImage: "note.text")
                                }

                                Menu {
                                    let otherChapters = appState.document.chapters.filter { $0.id != chapter.id }
                                    if otherChapters.isEmpty {
                                        Text("移動先の章がありません")
                                    } else {
                                        ForEach(otherChapters) { destination in
                                            Button(destination.title) {
                                                _ = appState.moveEpisode(
                                                    id: episode.id,
                                                    from: chapter.id,
                                                    to: destination.id
                                                )
                                            }
                                        }
                                    }
                                } label: {
                                    Label("別の章へ移動", systemImage: "arrow.right")
                                }

                                Button(role: .destructive) {
                                    episodePendingDeletion = EpisodeDeletionRequest(
                                        episode: episode,
                                        chapterID: chapter.id
                                    )
                                } label: {
                                    Label("話を削除", systemImage: "trash")
                                }
                            }
                            .tag(WritingOutlineSelection.episode(episode.id))
                    }
                    .onMove { offsets, destination in
                        guard appState.outlinePresentation.searchText.isEmpty else { return }
                        appState.moveEpisodes(in: chapter.id, fromOffsets: offsets, toOffset: destination)
                    }
                }
                .onMove { offsets, destination in
                    guard appState.outlinePresentation.searchText.isEmpty else { return }
                    appState.moveChapters(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .workbenchOutlineListStyle()
        .overlay {
            if filteredChapters.isEmpty {
                ContentUnavailableView(
                    "章または話がありません",
                    systemImage: "doc.text",
                    description: Text("上部の + から章を追加できます。")
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
                chapter.episodes.contains { $0.title.localizedStandardContains(query) || $0.content.localizedStandardContains(query) }
        }
    }

    private func filteredEpisodes(in chapter: Chapter) -> [Episode] {
        let query = appState.outlinePresentation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chapter.episodes }
        guard !chapter.title.localizedStandardContains(query) else { return chapter.episodes }
        return chapter.episodes.filter { episode in
            episode.title.localizedStandardContains(query) || episode.content.localizedStandardContains(query)
        }
    }

    private var selectionBinding: Binding<WritingOutlineSelection?> {
        Binding(
            get: {
                if let selectedEpisodeID = appState.selectedEpisodeID {
                    return .episode(selectedEpisodeID)
                }
                return appState.selectedChapterID.map(WritingOutlineSelection.chapter)
            },
            set: { selection in
                switch selection {
                case let .chapter(chapterID):
                    appState.selectChapter(chapterID)
                case let .episode(episodeID):
                    appState.selectEpisode(episodeID)
                case nil:
                    break
                }
            }
        )
    }
}

private enum WritingOutlineSelection: Hashable {
    case chapter(ChapterID)
    case episode(EpisodeID)
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
                Label("\(chapter.episodes.count)話", systemImage: "text.book.closed")
                    .help("話数: \(chapter.episodes.count)")
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
            systemName: chapter.episodes.allSatisfy(\.memo.isEmpty) ? "note.text" : "note.text.badge.plus",
            help: chapter.episodes.allSatisfy(\.memo.isEmpty) ? "話メモ: なし" : "話メモ: あり"
        )
    }

    private func metadataIcon(systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help(help)
    }
}

private struct OutlineEpisodeRow: View {
    @Environment(AppState.self) private var appState

    let episode: Episode
    let chapterID: ChapterID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EpisodeTitleField(
                episode: episode,
                onTitleChange: { title in
                    appState.updateEpisodeTitle(title, for: episode.id, in: chapterID)
                },
                onCommit: {
                    appState.commitEpisodeTitleEditing()
                }
            )
            .lineLimit(1)
            .truncationMode(.tail)

            HStack(spacing: 8) {
                metadataIcon(
                    systemName: "textformat.size",
                    help: "文字数: \(ManuscriptMetrics.countCharacters(in: episode.content))字"
                )
                metadataIcon(
                    systemName: appState.saveState.systemImage,
                    help: "保存状態: \(appState.saveState.label)"
                )
                metadataIcon(
                    systemName: episode.memo.isEmpty ? "note.text" : "note.text.badge.plus",
                    help: episode.memo.isEmpty ? "話メモ: なし" : "話メモ: あり"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .padding(.vertical, 4)
    }

    private func metadataIcon(systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help(help)
    }
}

private struct EpisodeTitleField: View {
    let episode: Episode
    let onTitleChange: (String) -> Void
    let onCommit: () -> Void

    @State private var draftTitle: String
    @FocusState private var isFocused: Bool

    init(episode: Episode, onTitleChange: @escaping (String) -> Void, onCommit: @escaping () -> Void) {
        self.episode = episode
        self.onTitleChange = onTitleChange
        self.onCommit = onCommit
        _draftTitle = State(initialValue: episode.title)
    }

    var body: some View {
        TextField("話タイトル", text: $draftTitle)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onChange(of: draftTitle) {
                onTitleChange(draftTitle)
            }
            .onChange(of: episode.title) {
                if !isFocused {
                    draftTitle = episode.title
                }
            }
            .onChange(of: isFocused) {
                if !isFocused {
                    commit()
                }
            }
            .onSubmit {
                commit()
            }
    }

    private func commit() {
        let normalizedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let committedTitle = normalizedTitle.isEmpty ? Episode.defaultTitle : normalizedTitle
        if draftTitle != committedTitle {
            draftTitle = committedTitle
            onTitleChange(committedTitle)
        }
        onCommit()
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
        .onAppear {
            isFocused = true
        }
    }
}

struct EditorPaneView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorSearchSession.self) private var editorSearchSession
    @Environment(EditorCommandSession.self) private var editorCommandSession

    var body: some View {
        Group {
            if let episode = appState.selectedEpisode {
                VStack(spacing: 0) {
                    ZStack {
                        Color(hex: editorSettings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor)
                        EditorView(
                            chapterKey: episode.id,
                            initialText: episode.content,
                            selectionRequest: editorSearchSession.selectionRequest,
                            commandSession: editorCommandSession,
                            configuration: editorSettings.configuration,
                            onTextChange: { newText in
                                appState.updateSelectedEpisodeContent(newText)
                            }
                        )
                        .frame(maxWidth: editorMaximumWidth)
                    }

                    EditorAccessoryBar()
                }
            } else {
                ContentUnavailableView(
                    "話が選択されていません",
                    systemImage: "doc.text",
                    description: Text("Outlineから話を選択するか、話を追加してください。")
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

private struct EditorAccessoryBar: View {
    @Environment(EditorCommandSession.self) private var commandSession

    @State private var pendingOperation: PendingEditorOperation?
    @State private var notationSheet: NotationSheetState?
    @State private var lastReplacementID: UUID?
    @State private var replacementError: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                requestOperation(.punctuation("……"))
            } label: {
                Text("……")
            }
            .help("三点リーダーを挿入")

            Button {
                requestOperation(.punctuation("――"))
            } label: {
                Text("――")
            }
            .help("ダッシュを挿入")

            Button {
                requestOperation(.ruby)
            } label: {
                Text("ルビ")
            }
            .help("なろう形式のルビを追加")

            Button {
                requestOperation(.bouten)
            } label: {
                Text("傍点")
            }
            .disabled(!commandSession.hasNonEmptySelection)
            .help("なろう形式の傍点を追加")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .workbenchGlassChromeStyle()
        .disabled(commandSession.pendingCommand != nil || pendingOperation != nil || notationSheet != nil)
        .onChange(of: commandSession.selectionSnapshot) { _, snapshot in
            guard let pendingOperation, snapshot?.id == pendingOperation.id else { return }
            handleSelectionSnapshot(snapshot, for: pendingOperation)
        }
        .onChange(of: commandSession.rejectedCommandID) { _, rejectedID in
            guard rejectedID == pendingOperation?.id || rejectedID == notationSheet?.snapshot.id || rejectedID == lastReplacementID else { return }
            pendingOperation = nil
            notationSheet = nil
            replacementError = "本文または選択が変わったため、挿入できませんでした。選択し直して再度実行してください。"
        }
        .sheet(item: $notationSheet) { state in
            NotationInputSheet(
                state: state,
                onCancel: { notationSheet = nil }
            ) { notation in
                commandSession.replaceSelection(id: state.snapshot.id, text: notation)
                lastReplacementID = state.snapshot.id
                notationSheet = nil
            }
        }
        .alert("挿入できませんでした", isPresented: replacementErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(replacementError ?? "")
        }
    }

    private func requestOperation(_ operation: EditorAccessoryOperation) {
        guard pendingOperation == nil, notationSheet == nil, commandSession.pendingCommand == nil else { return }
        let id = commandSession.requestSelectionSnapshot()
        pendingOperation = PendingEditorOperation(id: id, operation: operation)
    }

    private func handleSelectionSnapshot(_ snapshot: EditorSelectionSnapshot?, for pendingOperation: PendingEditorOperation) {
        guard let snapshot else { return }
        self.pendingOperation = nil

        switch pendingOperation.operation {
        case let .punctuation(text):
            commandSession.replaceSelection(id: snapshot.id, text: text)
            lastReplacementID = snapshot.id
        case .ruby:
            notationSheet = NotationSheetState(operation: pendingOperation.operation, snapshot: snapshot)
        case .bouten:
            guard let notation = EditorNotationRules.bouten(text: snapshot.text) else {
                replacementError = "傍点を付ける文字を選択してください。"
                return
            }
            commandSession.replaceSelection(id: snapshot.id, text: notation)
            lastReplacementID = snapshot.id
        }
    }

    private var replacementErrorIsPresented: Binding<Bool> {
        Binding(
            get: { replacementError != nil },
            set: { isPresented in
                if !isPresented {
                    replacementError = nil
                }
            }
        )
    }
}

private enum EditorAccessoryOperation: Equatable {
    case punctuation(String)
    case ruby
    case bouten
}

private struct PendingEditorOperation: Equatable {
    let id: UUID
    let operation: EditorAccessoryOperation
}

private struct NotationSheetState: Identifiable {
    let operation: EditorAccessoryOperation
    let snapshot: EditorSelectionSnapshot

    var id: UUID {
        snapshot.id
    }
}

private struct NotationInputSheet: View {
    let state: NotationSheetState
    let onCancel: () -> Void
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var parentText: String
    @State private var rubyText = ""

    init(
        state: NotationSheetState,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (String) -> Void
    ) {
        self.state = state
        self.onCancel = onCancel
        self.onComplete = onComplete
        _parentText = State(initialValue: state.snapshot.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch state.operation {
                case .ruby:
                    TextField("親文字", text: $parentText)
                        .focused($focusedField, equals: .parent)
                    TextField("ルビ", text: $rubyText)
                        .focused($focusedField, equals: .ruby)
                case .bouten:
                    EmptyView()
                case .punctuation:
                    EmptyView()
                }

                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("キャンセル", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("追加") {
                    guard let notation else { return }
                    onComplete(notation)
                }
                .buttonStyle(.borderedProminent)
                .disabled(notation == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 360)
        .onAppear {
            if case .ruby = state.operation, !state.snapshot.text.isEmpty {
                focusedField = .ruby
            } else {
                focusedField = .parent
            }
        }
    }

    private var notation: String? {
        switch state.operation {
        case .ruby:
            EditorNotationRules.ruby(parentText: parentText, rubyText: rubyText)
        case .bouten:
            nil
        case .punctuation:
            nil
        }
    }

    private var previewText: String {
        notation ?? "入力するとプレビューが表示されます。"
    }

    private enum Field {
        case parent
        case ruby
    }
}
