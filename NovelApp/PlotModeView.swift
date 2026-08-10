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
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                switch focusedSelection {
                case .unassigned:
                    PlotCardCanvas(
                        chapterID: nil,
                        cards: cards(in: nil),
                        editingCardRequest: $editingCardRequest,
                        cardPendingDeletion: $cardPendingDeletion
                    )
                case let .chapter(focusedChapterID):
                    if let chapter = appState.document.chapters.first(where: { $0.id == focusedChapterID }) {
                        PlotCardCanvas(
                            chapterID: chapter.id,
                            cards: cards(in: chapter.id),
                            editingCardRequest: $editingCardRequest,
                            cardPendingDeletion: $cardPendingDeletion
                        )
                    } else {
                        ContentUnavailableView(
                            "章が見つかりません",
                            systemImage: "rectangle.stack",
                            description: Text("Outlineから章または未割り当てを選び直してください。")
                        )
                        .frame(width: 260)
                    }
                }
            }
            .padding(16)
        }
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
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("タイトル", text: selectedPlotCardTitleBinding)
                    .onSubmit {
                        appState.commitPlotCardEditing()
                    }

                Picker("章", selection: selectedPlotCardChapterBinding) {
                    Text("未割り当て")
                        .tag(nil as ChapterID?)
                    ForEach(appState.document.chapters) { chapter in
                        Text(chapter.title)
                            .tag(chapter.id as ChapterID?)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("メモ")
                        .foregroundStyle(.secondary)
                    TextEditor(text: selectedPlotCardMemoBinding)
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
            appState.commitPlotCardEditing()
        }
    }

    private var selectedPlotCardTitleBinding: Binding<String> {
        Binding(
            get: { appState.selectedPlotCard?.title ?? "" },
            set: { appState.updateSelectedPlotCard(title: $0) }
        )
    }

    private var selectedPlotCardMemoBinding: Binding<String> {
        Binding(
            get: { appState.selectedPlotCard?.memo ?? "" },
            set: { appState.updateSelectedPlotCard(memo: $0) }
        )
    }

    private var selectedPlotCardChapterBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selectedPlotCard?.chapterID },
            set: { appState.updateSelectedPlotCardChapter($0) }
        )
    }
}
