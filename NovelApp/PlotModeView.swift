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

    @State private var editingCardID: PlotCardID?
    @State private var cardPendingDeletion: PlotCard?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                PlotLaneView(
                    title: "未割り当て",
                    chapterID: nil,
                    cards: cards(in: nil),
                    editingCardID: $editingCardID,
                    cardPendingDeletion: $cardPendingDeletion
                )

                ForEach(appState.document.chapters) { chapter in
                    PlotLaneView(
                        title: chapter.title,
                        chapterID: chapter.id,
                        cards: cards(in: chapter.id),
                        editingCardID: $editingCardID,
                        cardPendingDeletion: $cardPendingDeletion
                    )
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

/// Toolbar-1 以前の HSplitView 互換ラッパ。新規呼び出しは `PlotBoardView` を使う。
struct PlotModeView: View {
    let onChapterJump: (ChapterID) -> Void

    var body: some View {
        PlotBoardView(onChapterJump: onChapterJump)
    }
}

private struct PlotLaneView: View {
    @Environment(AppState.self) private var appState

    let title: String
    let chapterID: ChapterID?
    let cards: [PlotCard]
    @Binding var editingCardID: PlotCardID?
    @Binding var cardPendingDeletion: PlotCard?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(cards.count)枚")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    appState.addPlotCard(chapterID: chapterID)
                } label: {
                    Label("カードを追加", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
            }

            VStack(spacing: 8) {
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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 8)
            }
            .dropDestination(for: PlotCardID.self) { items, _ in
                guard let droppedID = items.first else { return false }
                appState.movePlotCard(id: droppedID, toChapter: chapterID, before: nil)
                return true
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .topLeading)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
