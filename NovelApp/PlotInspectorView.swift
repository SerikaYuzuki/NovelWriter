import NovelCore
import SwiftUI

struct PlotInspectorView: View {
    @Environment(AppState.self) private var appState

    let onChapterJump: (ChapterID) -> Void

    @State private var plotCardPendingDeletion: PlotCard?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: plotCardSelectionBinding) {
                ForEach(appState.document.plotCards) { card in
                    PlotCardRow(card: card, chapterTitle: chapterTitle(for: card.chapterID))
                        .tag(card.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                plotCardPendingDeletion = card
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
                .onMove { offsets, destination in
                    appState.movePlotCards(fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minHeight: 130)

            Divider()

            HStack {
                Button {
                    appState.addPlotCard()
                } label: {
                    Label("追加", systemImage: "plus")
                }

                Button(role: .destructive) {
                    if let card = appState.selectedPlotCard {
                        plotCardPendingDeletion = card
                    }
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(appState.selectedPlotCard == nil)

                Spacer()
            }
            .padding(10)

            Divider()

            if appState.selectedPlotCard == nil {
                ContentUnavailableView("プロットカードが選択されていません", systemImage: "rectangle.stack")
                    .frame(maxHeight: .infinity)
            } else {
                PlotCardEditor(
                    title: selectedPlotCardTitleBinding,
                    memo: selectedPlotCardMemoBinding,
                    chapterID: selectedPlotCardChapterBinding,
                    chapters: appState.document.chapters,
                    onJump: {
                        if let chapterID = appState.selectedPlotCard?.chapterID {
                            onChapterJump(chapterID)
                        }
                    },
                    onCommit: {
                        appState.commitPlotCardEditing()
                    }
                )
            }
        }
        .confirmationDialog(
            "プロットカードを削除しますか？",
            isPresented: plotCardDeletionDialogIsPresented,
            presenting: plotCardPendingDeletion
        ) { card in
            Button("削除", role: .destructive) {
                appState.deletePlotCard(id: card.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { card in
            Text("「\(card.title)」を削除します。")
        }
    }

    private var plotCardSelectionBinding: Binding<PlotCardID?> {
        Binding(
            get: { appState.selectedPlotCardID },
            set: { appState.selectPlotCard($0) }
        )
    }

    private var plotCardDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { plotCardPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    plotCardPendingDeletion = nil
                }
            }
        )
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

    private func chapterTitle(for chapterID: ChapterID?) -> String? {
        guard let chapterID else { return nil }
        return appState.document.chapters.first { $0.id == chapterID }?.title
    }
}

private struct PlotCardRow: View {
    let card: PlotCard
    let chapterTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NovelDocument.normalizedPlotCardTitle(card.title))
                .lineLimit(1)
            if let chapterTitle {
                Text(chapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct PlotCardEditor: View {
    @Binding var title: String
    @Binding var memo: String
    @Binding var chapterID: ChapterID?

    let chapters: [Chapter]
    let onJump: () -> Void
    let onCommit: () -> Void

    var body: some View {
        Form {
            TextField("タイトル", text: $title)
                .onSubmit(onCommit)

            Picker("章", selection: $chapterID) {
                Text("未設定")
                    .tag(nil as ChapterID?)
                ForEach(chapters) { chapter in
                    Text(chapter.title)
                        .tag(chapter.id as ChapterID?)
                }
            }

            Button {
                onJump()
            } label: {
                Label("紐付き章へジャンプ", systemImage: "arrowshape.turn.up.right")
            }
            .disabled(chapterID == nil)

            VStack(alignment: .leading, spacing: 6) {
                Text("メモ")
                    .foregroundStyle(.secondary)
                TextEditor(text: $memo)
                    .frame(minHeight: 180)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .onDisappear(perform: onCommit)
    }
}
