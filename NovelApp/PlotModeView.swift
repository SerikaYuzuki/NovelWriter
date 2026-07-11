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

    @State private var editingCardID: PlotCardID?
    @State private var cardPendingDeletion: PlotCard?

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
                        editingCardID: $editingCardID,
                        cardPendingDeletion: $cardPendingDeletion
                    )
                case let .chapter(focusedChapterID):
                    if let chapter = appState.document.chapters.first(where: { $0.id == focusedChapterID }) {
                        PlotCardCanvas(
                            chapterID: chapter.id,
                            cards: cards(in: chapter.id),
                            editingCardID: $editingCardID,
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
                    editingCardID = nil
                    cardPendingDeletion = card
                },
                onClose: {
                    editingCardID = nil
                }
            )
            .frame(width: 420, height: 420)
        }
        .confirmationDialog(
            "プロットカードを削除しますか？",
            isPresented: cardDeletionDialogIsPresented,
            presenting: cardPendingDeletion
        ) { card in
            Button("削除", role: .destructive) {
                appState.deletePlotCard(id: card.id)
                if editingCardID == card.id {
                    editingCardID = nil
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { card in
            Text("「\(card.title)」を削除します。")
        }
        .onDeleteCommand {
            guard let selectedPlotCardID = appState.selectedPlotCardID,
                  let card = appState.document.plotCards.first(where: { $0.id == selectedPlotCardID }) else
            {
                return
            }
            cardPendingDeletion = card
        }
    }

    private func cards(in chapterID: ChapterID?) -> [PlotCard] {
        appState.document.plotCards.filter { $0.chapterID == chapterID }
    }

    private var editingCardBinding: Binding<PlotCard?> {
        Binding(
            get: {
                guard let editingCardID else { return nil }
                return appState.document.plotCards.first { $0.id == editingCardID }
            },
            set: { card in
                editingCardID = card?.id
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
               appState.document.plotCards.allSatisfy({ $0.chapterID != nil })
            {
                ContentUnavailableView(
                    "章がありません",
                    systemImage: "doc.text",
                    description: Text("執筆画面から章を追加できます。")
                )
            }
        }
    }

    private var plotOutlineSelectionBinding: Binding<PlotOutlineSelection?> {
        Binding(
            get: { appState.plotOutlineSelection },
            set: { selection in
                guard let selection else { return }
                appState.selectPlotOutline(selection)
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
                return appState.movePlotCardFromOutline(id: cardID, to: selection)
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
    }
}

/// Outlineの選択を文脈として、カードだけを横方向へ連続配置するcanvas。
private struct PlotCardCanvas: View {
    @Environment(AppState.self) private var appState

    let chapterID: ChapterID?
    let cards: [PlotCard]
    @Binding var editingCardID: PlotCardID?
    @Binding var cardPendingDeletion: PlotCard?

    var body: some View {
        ForEach(cards) { card in
            PlotBoardCard(
                card: card,
                onEdit: {
                    editingCardID = card.id
                    appState.selectPlotCard(card.id)
                },
                onDelete: {
                    cardPendingDeletion = card
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

        Button {
            appState.addPlotCard(chapterID: chapterID)
        } label: {
            Label("カードを追加", systemImage: "plus")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.borderless)
        .frame(width: 260)
        .frame(minHeight: 72)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        }
        .dropDestination(for: PlotCardID.self) { items, _ in
            guard let droppedID = items.first else { return false }
            appState.movePlotCard(id: droppedID, toChapter: chapterID, before: nil)
            return true
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
