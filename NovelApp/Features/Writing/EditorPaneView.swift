import AppKit
import EditorKit
import NovelCore
import NovelUI
import SwiftUI

struct EditorPaneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorSearchSession.self) private var editorSearchSession
    @Environment(EditorCommandSession.self) private var editorCommandSession
    @Binding private var isPlotCardRailPresented: Bool

    init(
        isPlotCardRailPresented: Binding<Bool> = .constant(false)
    ) {
        _isPlotCardRailPresented = isPlotCardRailPresented
    }

    var body: some View {
        Group {
            if let episode = appState.selectedEpisode,
               let chapterID = appState.selectedChapterID {
                let session = appState.documentSessionToken
                let isEditable = appState.permitsDocumentInteraction
                let editorCanvas = Color(hex: editorSettings.backgroundColorHex)
                    ?? Color(nsColor: .textBackgroundColor)
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack {
                            editorCanvas
                            EditorView(
                                chapterKey: SessionBoundEditorKey(
                                    value: episode.id,
                                    generation: appState.editorContentGeneration
                                ),
                                initialText: episode.content,
                                selectionRequest: editorSearchSession.selectionRequest,
                                commandSession: editorCommandSession,
                                aiSelectionSession: aiSelectionSession,
                                selectionContextMenuCommands: selectionCopyCommands(
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
                                        expectedEditorContentGeneration: appState.editorContentGeneration
                                    )
                                }
                            )
                            .frame(maxWidth: editorMaximumWidth)
                        }

                        if isPlotCardRailPresented {
                            WritingPlotCardRail(chapterID: chapterID)
                                .frame(height: 240)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(Motion.standard(reduceMotion: reduceMotion), value: isPlotCardRailPresented)

                    EditorAccessoryBar(
                        isEnabled: isEditable,
                        backgroundColor: editorCanvas
                    )
                }
            } else {
                ContentUnavailableView {
                    Label("話が選択されていません", systemImage: "doc.text")
                } description: {
                    Text("章・話の一覧から話を選択するか、話を追加してください。")
                } actions: {
                    Button("話を追加") { Task { _ = await appState.addEpisodeAfterTransition() } }
                        .disabled(appState.selectedChapterID == nil || !appState.permitsDocumentInteraction)
                }
            }
        }
        .focusedValue(\.workbenchSearchSurface, .editor)
        .onChange(of: appState.selectedEpisodeID) { _, newSelection in
            editorSearchSession.handleEpisodeChange(newSelection)
        }
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
    }

    private func selectionCopyCommands(
        episodeID: EpisodeID,
        chapterID: ChapterID,
        session: DocumentSessionToken
    ) -> [EditorSelectionContextMenuCommand] {
        [
            EditorSelectionContextMenuCommand(
                title: "選択範囲をコピー",
                systemImageName: "doc.on.doc"
            ) { snapshot in
                appState.copySelectionManuscript(
                    selectedText: snapshot.text,
                    episodeID: episodeID,
                    in: chapterID,
                    expectedSession: session
                )
            }
        ]
    }

    private var aiSelectionSession: EditorAISelectionSession? {
        nil
    }
}

private struct WritingPlotCardRail: View {
    @Environment(AppState.self) private var appState

    let chapterID: ChapterID

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView {
                    Label("プロットカードがありません", systemImage: "rectangle.stack")
                } description: {
                    Text("プロット画面からこの章のカードを追加できます。")
                } actions: {
                    Button("プロットを開く") { Task { _ = await appState.selectProjectSectionAfterTransition(.plot) } }
                        .disabled(!appState.permitsDocumentInteraction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(cards) { card in
                            WritingPlotCardReference(
                                card: card,
                                isSelected: appState.selectedPlotCardID == card.id,
                                onSelect: { appState.selectPlotCard(card.id) }
                            ).frame(width: 260)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .workbenchGlassChromeStyle()
        .accessibilityLabel("プロットカード一覧")
    }

    private var cards: [PlotCard] {
        appState.document.plotCards.filter { $0.chapterID == chapterID }
    }
}

private struct WritingPlotCardReference: View {
    let card: PlotCard
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                Text(NovelDocument.normalizedPlotCardTitle(card.title))
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !card.memo.isEmpty {
                    Text(card.memo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                .quaternary.opacity(isSelected ? 0.8 : 0.45),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NovelDocument.normalizedPlotCardTitle(card.title))
        .accessibilityHint("プロットカードを選択")
    }
}

private struct EditorAccessoryBar: View {
    @Environment(EditorCommandSession.self) private var commandSession
    let isEnabled: Bool
    let backgroundColor: Color

    @State private var pendingOperation: PendingEditorOperation?
    @State private var notationSheet: NotationSheetState?
    @State private var lastReplacementID: UUID?
    @State private var replacementError: String?

    var body: some View {
        HStack(spacing: 8) {
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
            }
            .disabled(
                !isEnabled ||
                    !commandSession.hasActiveEditorSurface ||
                    commandSession.isDocumentTransitionPrepared ||
                    commandSession.pendingCommand != nil ||
                    pendingOperation != nil ||
                    notationSheet != nil
            )
            Spacer()
            WritingAccessoryProgressView()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(backgroundColor)
        .overlay(alignment: .top) { Divider() }
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
