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

    @State private var chapterPendingDeletion: SessionBoundValue<Chapter>?
    @State private var episodePendingDeletion: EpisodeDeletionRequest?

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
        ) { request in
            Button("削除", role: .destructive) {
                Task {
                    await appState.deleteChapterAfterDeviceSyncDeparture(
                        id: request.value.id,
                        expectedSession: request.session
                    )
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.value.title)」を削除します。")
        }
        .confirmationDialog(
            "話を削除しますか？",
            isPresented: episodeDeletionDialogIsPresented,
            presenting: episodePendingDeletion
        ) { request in
            Button("削除", role: .destructive) {
                Task {
                    await appState.deleteEpisodeAfterDeviceSyncDeparture(
                        id: request.episode.id,
                        from: request.chapterID,
                        expectedSession: request.session
                    )
                }
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

struct OutlineView: View {
    @Environment(AppState.self) private var appState

    @Binding var chapterPendingDeletion: SessionBoundValue<Chapter>?
    @Binding var episodePendingDeletion: EpisodeDeletionRequest?

    @State private var disclosureState = OutlineDisclosureState()
    @State private var chapterPendingRename: SessionBoundValue<Chapter>?
    @State private var chapterTitleDraft = ""

    var body: some View {
        List(selection: selectionBinding) {
            Section("原稿") {
                ForEach(sessionBoundChapters) { chapterItem in
                    let chapter = chapterItem.value
                    DisclosureGroup(isExpanded: expansionBinding(for: chapter.id)) {
                        ForEach(sessionBoundEpisodes(in: chapter, session: chapterItem.session)) { episodeRequest in
                            let episode = episodeRequest.episode
                            OutlineEpisodeRow(
                                episode: episode,
                                chapterID: chapter.id,
                                expectedSession: episodeRequest.session,
                                showsSaveState: OutlineSaveStateVisibility.episode(
                                    episode.id,
                                    selectedEpisodeID: appState.selectedEpisodeID
                                )
                            )
                            .contextMenu {
                                EpisodeOutlineContextMenu(request: episodeRequest) {
                                    episodePendingDeletion = episodeRequest
                                }
                            }
                            .tag(episode.id)
                        }
                        .onMove { offsets, destination in
                            guard appState.outlinePresentation.searchText.isEmpty else { return }
                            Task {
                                await appState.moveEpisodesAfterDeviceSyncDeparture(
                                    in: chapter.id,
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                            }
                        }
                    } label: {
                        OutlineChapterRow(
                            chapter: chapter,
                            expectedSession: chapterItem.session,
                            showsSaveState: OutlineSaveStateVisibility.chapter(
                                chapter.id,
                                selectedChapterID: appState.selectedChapterID,
                                selectedEpisodeID: appState.selectedEpisodeID
                            )
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            disclosureState.toggle(chapter.id)
                        }
                        .accessibilityAction(named: "話一覧を開閉") {
                            disclosureState.toggle(chapter.id)
                        }
                        .accessibilityAction(named: "章タイトルを編集") {
                            beginEditingTitle(for: chapterItem)
                        }
                        .accessibilityHint("クリックすると話一覧を開閉します")
                        .contextMenu {
                            ChapterOutlineContextMenu(
                                chapterItem: chapterItem,
                                onRename: { beginEditingTitle(for: chapterItem) },
                                onReveal: { disclosureState.reveal(chapter.id) },
                                onDelete: { chapterPendingDeletion = chapterItem }
                            )
                        }
                    }
                }
                .onMove { offsets, destination in
                    guard appState.outlinePresentation.searchText.isEmpty else { return }
                    Task {
                        await appState.moveChaptersAfterDeviceSyncDeparture(
                            fromOffsets: offsets,
                            toOffset: destination
                        )
                    }
                }
            }
        }
        .workbenchOutlineListStyle()
        .overlay {
            if filteredChapters.isEmpty {
                ContentUnavailableView(
                    "章または話がありません",
                    systemImage: "doc.text",
                    description: Text("上部の「章を追加」または章メニューから追加できます。")
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
        .alert("章タイトルを編集", isPresented: chapterRenameDialogIsPresented) {
            TextField("章タイトル", text: $chapterTitleDraft)
            Button("変更") {
                commitChapterTitleRename()
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("章の表示名を変更します。")
        }
        .onAppear {
            disclosureState.reset(
                chapterIDs: chapterIDs,
                revealing: appState.selectedChapterID
            )
            revealSearchMatches()
        }
        .onChange(of: appState.documentSessionToken) {
            chapterPendingRename = nil
            disclosureState.reset(
                chapterIDs: chapterIDs,
                revealing: appState.selectedChapterID
            )
            revealSearchMatches()
        }
        .onChange(of: chapterIDs) { _, newChapterIDs in
            disclosureState.synchronize(
                chapterIDs: newChapterIDs,
                revealing: appState.selectedChapterID
            )
            if let chapterPendingRename, !newChapterIDs.contains(chapterPendingRename.value.id) {
                self.chapterPendingRename = nil
            }
        }
        .onChange(of: appState.selectedChapterID) { _, chapterID in
            if let chapterID {
                disclosureState.reveal(chapterID)
            }
        }
        .onChange(of: appState.selectedEpisodeID) { _, episodeID in
            if episodeID != nil, let chapterID = appState.selectedChapterID {
                disclosureState.reveal(chapterID)
            }
        }
        .onChange(of: normalizedSearchQuery) {
            revealSearchMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentChapterTitleEditor)) { _ in
            guard appState.permitsDocumentInteraction,
                  let chapter = appState.selectedChapter else { return }
            beginEditingTitle(
                for: SessionBoundValue(
                    value: chapter,
                    session: appState.documentSessionToken
                )
            )
        }
    }

    private var filteredChapters: [Chapter] {
        let query = appState.outlinePresentation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.document.chapters }
        return appState.document.chapters.filter { chapter in
            chapter.title.localizedStandardContains(query) ||
                chapter.episodes.contains {
                    $0.title.localizedStandardContains(query) ||
                        $0.content.localizedStandardContains(query)
                }
        }
    }

    private var sessionBoundChapters: [SessionBoundValue<Chapter>] {
        let session = appState.documentSessionToken
        return filteredChapters.map {
            SessionBoundValue(value: $0, session: session)
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

    private func sessionBoundEpisodes(
        in chapter: Chapter,
        session: DocumentSessionToken
    ) -> [EpisodeDeletionRequest] {
        filteredEpisodes(in: chapter).map {
            EpisodeDeletionRequest(episode: $0, chapterID: chapter.id, session: session)
        }
    }

    private var selectionBinding: Binding<EpisodeID?> {
        Binding(
            get: { appState.selectedEpisodeID },
            set: { episodeID in
                guard let episodeID,
                      let chapter = appState.document.chapters.first(where: {
                          $0.episodes.contains(where: { $0.id == episodeID })
                      }) else { return }
                Task {
                    await appState.selectEpisodeAfterDeviceSyncDeparture(
                        episodeID,
                        in: chapter.id
                    )
                }
            }
        )
    }

    private var chapterIDs: [ChapterID] {
        appState.document.chapters.map(\.id)
    }

    private var normalizedSearchQuery: String {
        appState.outlinePresentation.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func expansionBinding(for chapterID: ChapterID) -> Binding<Bool> {
        Binding(
            get: {
                disclosureState.isExpanded(chapterID)
            },
            set: { isExpanded in
                disclosureState.setExpanded(isExpanded, for: chapterID)
            }
        )
    }

    private var chapterRenameDialogIsPresented: Binding<Bool> {
        Binding(
            get: { chapterPendingRename != nil },
            set: { isPresented in
                if !isPresented {
                    chapterPendingRename = nil
                }
            }
        )
    }

    private func beginEditingTitle(for chapterItem: SessionBoundValue<Chapter>) {
        disclosureState.reveal(chapterItem.value.id)
        chapterTitleDraft = chapterItem.value.title
        chapterPendingRename = chapterItem
    }

    private func commitChapterTitleRename() {
        guard let request = chapterPendingRename else { return }
        chapterPendingRename = nil
        guard request.session == appState.documentSessionToken,
              appState.document.chapters.contains(where: { $0.id == request.value.id }) else { return }

        let trimmedTitle = chapterTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateChapterTitle(trimmedTitle.isEmpty ? "無題の章" : trimmedTitle, for: request.value.id)
        appState.commitChapterTitleEditing()
    }

    private func revealSearchMatches() {
        guard !normalizedSearchQuery.isEmpty else { return }
        disclosureState.reveal(filteredChapters.map(\.id))
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
    #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
    @Environment(\.experimentalAISelectionSession) private var experimentalAISelectionSession
    @Environment(AIProofreadingOperation.self) private var aiProofreadingOperation
    #endif

    var body: some View {
        Group {
            if let episode = appState.selectedEpisode,
               let chapterID = appState.selectedChapterID,
               let syncLookup = appState.currentDeviceSyncLookupIdentity {
                let session = appState.documentSessionToken
                let isEditable = appState.deviceSyncAllowsEditing(for: syncLookup)
                VStack(spacing: 0) {
                    DeviceSyncStatusBanner(
                        state: appState.deviceSyncState,
                        transferState: appState.deviceSyncTransferState,
                        identity: appState.activeDeviceSyncIdentity
                    ) { expectedIdentity in
                        Task { await appState.forceContinueOnThisMac(expectedIdentity: expectedIdentity) }
                    }

                    ZStack {
                        Color(hex: editorSettings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor)
                        EditorView(
                            chapterKey: SessionBoundEditorKey(
                                value: episode.id,
                                generation: appState.editorContentGeneration
                            ),
                            initialText: episode.content,
                            selectionRequest: editorSearchSession.selectionRequest,
                            commandSession: editorCommandSession,
                            aiSelectionSession: aiSelectionSession,
                            selectionContextMenuCommands: selectionPromptCommands(
                                episodeID: episode.id,
                                chapterID: chapterID,
                                session: session
                            ),
                            configuration: editorSettings.configuration,
                            isEditable: isEditable,
                            onTextChange: { newText in
                                appState.updateEpisodeContent(
                                    newText,
                                    for: episode.id,
                                    in: chapterID,
                                    expectedSession: session,
                                    expectedEditorContentGeneration: syncLookup.editorContentGeneration
                                )
                                #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
                                aiProofreadingOperation.refreshApplicability()
                                #endif
                            }
                        )
                        .frame(maxWidth: editorMaximumWidth)
                    }

                    EditorAccessoryBar(isEnabled: isEditable)
                }
                .task(id: syncLookup) {
                    await appState.prepareDeviceSync(for: syncLookup)
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
        .sheet(isPresented: deviceSyncConflictIsPresented) {
            if let conflict = appState.deviceSyncConflict {
                DeviceSyncConflictResolutionView(
                    conflict: conflict,
                    state: appState.deviceSyncState,
                    recoveredContent: appState.pendingDeviceSyncConflictResolution.flatMap {
                        $0.conflict == conflict ? $0.content : nil
                    }
                ) { choice in
                    Task {
                        await appState.resolveDeviceSyncConflict(
                            using: choice,
                            expectedConflict: conflict
                        )
                    }
                }
                .id(conflict)
            }
        }
        #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
        .onDisappear {
                aiProofreadingOperation.editorSurfaceDidBecomeUnavailable()
            }
        #endif
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
    }

    private var deviceSyncConflictIsPresented: Binding<Bool> {
        Binding(
            get: { appState.deviceSyncConflict != nil },
            set: { _ in }
        )
    }

    private func selectionPromptCommands(
        episodeID: EpisodeID,
        chapterID: ChapterID,
        session: DocumentSessionToken
    ) -> [EditorSelectionContextMenuCommand] {
        [
            EditorSelectionContextMenuCommand(
                title: "選択範囲の校正用プロンプトをコピー",
                systemImageName: "checkmark.bubble"
            ) { snapshot in
                appState.copySelectionAIChatPrompt(
                    purpose: .proofreading,
                    selectedText: snapshot.text,
                    episodeID: episodeID,
                    in: chapterID,
                    expectedSession: session
                )
            },
            EditorSelectionContextMenuCommand(
                title: "選択範囲のアドバイス用プロンプトをコピー",
                systemImageName: "lightbulb"
            ) { snapshot in
                appState.copySelectionAIChatPrompt(
                    purpose: .advice,
                    selectedText: snapshot.text,
                    episodeID: episodeID,
                    in: chapterID,
                    expectedSession: session
                )
            }
        ]
    }

    private var aiSelectionSession: EditorAISelectionSession? {
        #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
        experimentalAISelectionSession
        #else
        nil
        #endif
    }
}

private struct EditorAccessoryBar: View {
    @Environment(EditorCommandSession.self) private var commandSession
    let isEnabled: Bool

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
        .disabled(
            !isEnabled ||
                !commandSession.hasActiveEditorSurface ||
                commandSession.isDocumentTransitionPrepared ||
                commandSession.pendingCommand != nil ||
                pendingOperation != nil ||
                notationSheet != nil
        )
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
