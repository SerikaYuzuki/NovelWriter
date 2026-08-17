import AppKit
import EditorKit
import NovelCore
import NovelUI
import SwiftUI

struct EditorPaneView: View {
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
               let chapterID = appState.selectedChapterID,
               let syncLookup = appState.currentDeviceSyncLookupIdentity {
                let session = appState.documentSessionToken
                let isEditable = appState.deviceSyncAllowsEditing(for: syncLookup)
                let editorCanvas = Color(hex: editorSettings.backgroundColorHex)
                    ?? Color(nsColor: .textBackgroundColor)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
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
                                }
                            )
                            .frame(maxWidth: editorMaximumWidth)
                        }

                        if isPlotCardRailPresented {
                            WritingPlotCardRail(
                                chapterID: chapterID,
                                onClose: { isPlotCardRailPresented = false }
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: isPlotCardRailPresented)

                    EditorAccessoryBar(
                        isEnabled: isEditable,
                        backgroundColor: editorCanvas
                    )
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
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
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
        nil
    }
}

private struct WritingPlotCardRail: View {
    @Environment(AppState.self) private var appState

    let chapterID: ChapterID
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("プロットカード", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Label("閉じる", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("プロットカードを閉じる")
            }
            .padding(12)

            Divider()

            if cards.isEmpty {
                ContentUnavailableView(
                    "プロットカードがありません",
                    systemImage: "rectangle.stack",
                    description: Text("プロット画面からこの章のカードを追加できます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(cards) { card in
                            WritingPlotCardReference(
                                card: card,
                                isSelected: appState.selectedPlotCardID == card.id,
                                onSelect: { appState.selectPlotCard(card.id) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .workbenchGlassChromeStyle()
        .overlay(alignment: .leading) {
            Divider()
        }
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
        .background(backgroundColor)
        .overlay(alignment: .top) { Divider() }
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
