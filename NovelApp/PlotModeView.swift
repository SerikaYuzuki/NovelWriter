import AppKit
import CoreTransferable
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

extension PlotCardID: @retroactive Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

struct PlotBoardView: View {
    @Environment(AppState.self) private var appState

    let onChapterJump: (ChapterID) -> Void
    let focusedSelection: PlotOutlineSelection

    @State private var editingCardRequest: SessionBoundValue<PlotCard>?
    @State private var cardPendingDeletion: SessionBoundValue<PlotCard>?

    init(
        focusedSelection: PlotOutlineSelection = .unassigned,
        onChapterJump: @escaping (ChapterID) -> Void
    ) {
        self.focusedSelection = focusedSelection
        self.onChapterJump = onChapterJump
    }

    var body: some View {
        boardContent
            .sheet(item: editingCardBinding) { card in
                PlotCardDetailSheet(
                    card: card,
                    onDelete: {
                        guard let editingCardRequest else { return }
                        self.editingCardRequest = nil
                        cardPendingDeletion = editingCardRequest
                    },
                    onClose: {
                        editingCardRequest = nil
                    }
                )
                .frame(width: 420, height: 420)
            }
            .confirmationDialog(
                "プロットカードを削除しますか？",
                isPresented: cardDeletionDialogIsPresented,
                presenting: cardPendingDeletion
            ) { request in
                Button("削除", role: .destructive) {
                    appState.deletePlotCard(id: request.value.id, expectedSession: request.session)
                    if editingCardRequest?.value.id == request.value.id {
                        editingCardRequest = nil
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { request in
                Text("「\(request.value.title)」を削除します。")
            }
            .onDeleteCommand {
                guard let selectedPlotCardID = appState.selectedPlotCardID,
                      let card = appState.document.plotCards.first(where: { $0.id == selectedPlotCardID }) else {
                    return
                }
                cardPendingDeletion = SessionBoundValue(
                    value: card,
                    session: appState.documentSessionToken
                )
            }
    }

    @ViewBuilder
    private var boardContent: some View {
        switch focusedSelection {
        case .unassigned:
            cardBoard(chapterID: nil, cards: cards(in: nil))
        case let .chapter(focusedChapterID):
            if let chapter = appState.document.chapters.first(where: { $0.id == focusedChapterID }) {
                cardBoard(chapterID: chapter.id, cards: cards(in: chapter.id))
            } else {
                ContentUnavailableView(
                    "章が見つかりません",
                    systemImage: "rectangle.stack",
                    description: Text("Outlineから章または未割り当てを選び直してください。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func cardBoard(
        chapterID: ChapterID?,
        cards: [SessionBoundValue<PlotCard>]
    ) -> some View {
        if cards.isEmpty {
            ContentUnavailableView(
                "プロットカードがありません",
                systemImage: "rectangle.stack",
                description: Text("上部の「プロットカードを追加」またはプロットメニューから追加できます。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .contentShape(Rectangle())
            .dropDestination(for: PlotCardID.self) { items, _ in
                guard let droppedID = items.first else { return false }
                appState.movePlotCard(id: droppedID, toChapter: chapterID, before: nil)
                return true
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyHStack(alignment: .top, spacing: 16) {
                    PlotCardCanvas(
                        chapterID: chapterID,
                        cards: cards,
                        editingCardRequest: $editingCardRequest,
                        cardPendingDeletion: $cardPendingDeletion
                    )
                }
                .padding(16)
            }
        }
    }

    private func cards(in chapterID: ChapterID?) -> [SessionBoundValue<PlotCard>] {
        let session = appState.documentSessionToken
        return appState.document.plotCards
            .filter { $0.chapterID == chapterID }
            .map { SessionBoundValue(value: $0, session: session) }
    }

    private var editingCardBinding: Binding<PlotCard?> {
        Binding(
            get: {
                guard let editingCardRequest,
                      editingCardRequest.session == appState.documentSessionToken else { return nil }
                return appState.document.plotCards.first { $0.id == editingCardRequest.value.id }
            },
            set: { card in
                editingCardRequest = card.map {
                    SessionBoundValue(value: $0, session: appState.documentSessionToken)
                }
            }
        )
    }

    private var cardDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { cardPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    cardPendingDeletion = nil
                }
            }
        )
    }
}

/// Toolbar-1以前の互換ラッパ。新規呼び出しは`PlotBoardView`を使う。
struct PlotModeView: View {
    let onChapterJump: (ChapterID) -> Void

    var body: some View {
        PlotBoardView(onChapterJump: onChapterJump)
    }
}

/// プロット画面のcontent列。執筆Outlineと同じsidebar list規約で章を選択する。
struct PlotChapterOutlineView: View {
    @Environment(AppState.self) private var appState

    @State private var dropTarget: PlotOutlineSelection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: plotOutlineSelectionBinding) {
                Section("章") {
                    PlotUnassignedOutlineRow(
                        cardCount: appState.document.plotCards.count { $0.chapterID == nil }
                    )
                    .plotOutlineDropTarget(.unassigned, targetedSelection: $dropTarget)
                    .tag(PlotOutlineSelection.unassigned)

                    ForEach(appState.document.chapters) { chapter in
                        PlotChapterOutlineRow(
                            chapter: chapter,
                            cardCount: appState.document.plotCards.count { $0.chapterID == chapter.id },
                            flagCount: flagCount(for: chapter.id)
                        )
                        .plotOutlineDropTarget(.chapter(chapter.id), targetedSelection: $dropTarget)
                        .tag(PlotOutlineSelection.chapter(chapter.id))
                    }
                }
            }
            .workbenchGlassOutlineStyle()
            .overlay {
                if appState.document.chapters.isEmpty,
                   appState.document.plotCards.allSatisfy({ $0.chapterID != nil }) {
                    ContentUnavailableView(
                        "章がありません",
                        systemImage: "doc.text",
                        description: Text("上部の「章を追加」または章メニューから追加できます。")
                    )
                }
            }
        }
    }

    private var plotOutlineSelectionBinding: Binding<PlotOutlineSelection?> {
        Binding(
            get: { appState.plotOutlineSelection },
            set: { selection in
                guard let selection else { return }
                Task {
                    await appState.selectPlotOutlineAfterDeviceSyncDeparture(selection)
                }
            }
        )
    }

    private func flagCount(for chapterID: ChapterID) -> Int {
        appState.document.flags.reduce(into: 0) { count, flag in
            if flag.plantedChapterID == chapterID || flag.resolvedChapterID == chapterID {
                count += 1
            }
        }
    }
}

private extension View {
    func plotOutlineDropTarget(
        _ selection: PlotOutlineSelection,
        targetedSelection: Binding<PlotOutlineSelection?>
    ) -> some View {
        modifier(PlotOutlineDropTargetModifier(selection: selection, targetedSelection: targetedSelection))
    }
}

private struct PlotOutlineDropTargetModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    let selection: PlotOutlineSelection
    @Binding var targetedSelection: PlotOutlineSelection?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                if targetedSelection == selection {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.16))
                        }
                }
            }
            .dropDestination(for: PlotCardID.self) { items, _ in
                guard let cardID = items.first else { return false }
                Task {
                    await appState.movePlotCardFromOutlineAfterDeviceSyncDeparture(
                        id: cardID,
                        to: selection
                    )
                }
                return true
            } isTargeted: { isTargeted in
                targetedSelection = isTargeted ? selection : nil
            }
    }
}

private struct PlotUnassignedOutlineRow: View {
    let cardCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("未割り当て")
                .lineLimit(1)
            HStack(spacing: 8) {
                Label("\(cardCount)枚", systemImage: "rectangle.stack")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

private struct PlotChapterOutlineRow: View {
    let chapter: Chapter
    let cardCount: Int
    let flagCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chapter.title)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Label("\(cardCount)枚", systemImage: "rectangle.stack")
                Label("\(flagCount)件", systemImage: "flag")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

/// 上段のプロットと下段の伏線を分離するdetail列。
struct PlotAndFlagSplitView: View {
    @Environment(AppState.self) private var appState

    let onChapterJump: (ChapterID) -> Void

    var body: some View {
        VSplitView {
            PlotBoardView(
                focusedSelection: appState.plotOutlineSelection,
                onChapterJump: onChapterJump
            )
            .frame(
                minWidth: nil,
                idealWidth: nil,
                maxWidth: .infinity,
                minHeight: 320,
                idealHeight: 480,
                maxHeight: .infinity
            )

            FlagSectionView(onChapterJump: onChapterJump)
                .frame(
                    minWidth: nil,
                    idealWidth: nil,
                    maxWidth: .infinity,
                    minHeight: 220,
                    idealHeight: 240,
                    maxHeight: .infinity
                )
        }
        .workbenchGlassChromeStyle()
    }
}

/// Outlineの選択を文脈として、カードだけを横方向へ連続配置するcanvas。
private struct PlotCardCanvas: View {
    @Environment(AppState.self) private var appState

    let chapterID: ChapterID?
    let cards: [SessionBoundValue<PlotCard>]
    @Binding var editingCardRequest: SessionBoundValue<PlotCard>?
    @Binding var cardPendingDeletion: SessionBoundValue<PlotCard>?

    var body: some View {
        if cards.isEmpty {
            ContentUnavailableView(
                "プロットカードがありません",
                systemImage: "rectangle.stack",
                description: Text("上部の「プロットカードを追加」またはプロットメニューから追加できます。")
            )
            .frame(width: 260)
            .frame(minHeight: 120)
            .dropDestination(for: PlotCardID.self) { items, _ in
                guard let droppedID = items.first else { return false }
                appState.movePlotCard(id: droppedID, toChapter: chapterID, before: nil)
                return true
            }
        } else {
            ForEach(cards) { item in
                let card = item.value
                PlotBoardCard(
                    card: card,
                    onEdit: {
                        editingCardRequest = item
                        appState.selectPlotCard(card.id)
                    },
                    onDelete: {
                        cardPendingDeletion = item
                    }
                )
                .frame(width: 260, alignment: .topLeading)
                .draggable(card.id)
                .dropDestination(for: PlotCardID.self) { items, _ in
                    guard let droppedID = items.first else { return false }
                    appState.movePlotCard(id: droppedID, toChapter: chapterID, before: card.id)
                    return true
                }
            }
        }
    }
}

private struct PlotBoardCard: View {
    let card: PlotCard
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 8) {
                Text(NovelDocument.normalizedPlotCardTitle(card.title))
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !card.memo.isEmpty {
                    Text(card.memo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("編集") {
                onEdit()
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }
}

private struct PlotCardDetailSheet: View {
    @Environment(AppState.self) private var appState

    let card: PlotCard
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var titleDraft: String
    @State private var memoDraft: String
    @State private var chapterDraft: ChapterID?

    init(
        card: PlotCard,
        onDelete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.card = card
        self.onDelete = onDelete
        self.onClose = onClose
        _titleDraft = State(initialValue: card.title)
        _memoDraft = State(initialValue: card.memo)
        _chapterDraft = State(initialValue: card.chapterID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("タイトル", text: $titleDraft)
                    .onSubmit {
                        commitDraft()
                        appState.commitPlotCardEditing()
                    }

                Picker("章", selection: $chapterDraft) {
                    Text("未割り当て")
                        .tag(nil as ChapterID?)
                    ForEach(appState.document.chapters) { chapter in
                        Text(chapter.title)
                            .tag(chapter.id as ChapterID?)
                    }
                }

                WorkbenchLabeledEditor("メモ") {
                    PlotCardMemoEditor(
                        editorID: card.id,
                        initialText: memoDraft,
                        text: $memoDraft
                    )
                    .frame(minHeight: 180)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(role: .destructive, action: onDelete) {
                    Label("削除", systemImage: "trash")
                }
                Spacer()
                Button("閉じる", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .onAppear {
            appState.selectPlotCard(card.id)
        }
        .onDisappear {
            commitDraft()
            appState.commitPlotCardEditing()
        }
    }

    private func commitDraft() {
        appState.updateSelectedPlotCard(title: titleDraft, memo: memoDraft)
        appState.updateSelectedPlotCardChapter(chapterDraft)
    }
}

/// プロット本文の入力中はNSTextViewを唯一の正にし、SwiftUIの再描画で
/// marked textを古いdraftへ戻さない。執筆本文と同じく、IME確定後だけdraftへ通知する。
private struct PlotCardMemoEditor: NSViewRepresentable {
    let editorID: PlotCardID
    let initialText: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommittedText: { text = $0 })
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() は常にNSTextViewをdocumentViewに持つ")
        }

        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.string = initialText
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0

        context.coordinator.editorID = editorID
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.onCommittedText = { text = $0 }
        guard let textView = context.coordinator.textView else { return }
        guard context.coordinator.editorID != editorID else { return }

        if textView.hasMarkedText() {
            textView.unmarkText()
        }
        textView.string = initialText
        textView.undoManager?.removeAllActions()
        context.coordinator.editorID = editorID
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onCommittedText: (String) -> Void
        var editorID: PlotCardID?
        weak var textView: NSTextView?

        init(onCommittedText: @escaping (String) -> Void) {
            self.onCommittedText = onCommittedText
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard let changedTextView = notification.object as? NSTextView else { return }
            textView = changedTextView
            guard !changedTextView.hasMarkedText() else { return }
            onCommittedText(changedTextView.string)
        }
    }
}
