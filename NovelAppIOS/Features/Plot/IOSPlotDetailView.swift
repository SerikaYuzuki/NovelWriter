import NovelCore
import SwiftUI

struct IOSPlotDetailView: View {
    let store: IOSDocumentStore
    let selection: IOSPlotSelection?
    let expectedSession: IOSDocumentSessionToken?
    var dismissAfterDeletion = false
    var onDeletion: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var deletionRequest: IOSPlotItemDeletionRequest?

    var body: some View {
        Group {
            switch selection {
            case let .card(id):
                if let card = store.document.plotCards.first(where: { $0.id == id }) {
                    plotCardForm(card)
                } else {
                    unavailableView
                }
            case let .flag(id):
                if let flag = store.document.flags.first(where: { $0.id == id }) {
                    flagForm(flag)
                } else {
                    unavailableView
                }
            case nil:
                unavailableView
            }
        }
        .confirmationDialog(
            deletionRequest?.title ?? "削除しますか？",
            isPresented: deletionRequestIsPresented,
            presenting: deletionRequest
        ) { request in
            Button("削除", role: .destructive) {
                performDeletion(request)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .iosWorkChrome(store: store, accessibilityPrefix: "ios.plot.detail")
    }

    private func plotCardForm(_ card: PlotCard) -> some View {
        Form {
            Section("プロットカード") {
                TextField(
                    "タイトル",
                    text: plotCardBinding(card.id, \.title, fallback: "")
                )
                .textInputAutocapitalization(.never)

                Picker(
                    "章",
                    selection: plotCardBinding(card.id, \.chapterID, fallback: nil)
                ) {
                    Text("章未設定")
                        .tag(nil as ChapterID?)
                    ForEach(store.document.chapters) { chapter in
                        Text(chapter.title.isEmpty ? "名称未設定の章" : chapter.title)
                            .tag(chapter.id as ChapterID?)
                    }
                }
            }

            Section("メモ") {
                TextEditor(text: plotCardBinding(card.id, \.memo, fallback: ""))
                    .frame(minHeight: 160)
                    .accessibilityLabel("プロットカードのメモ")
            }

            Section {
                Button("プロットカードを削除", role: .destructive) {
                    requestDeletion(.card(card.id), displayTitle: card.title)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("プロットカード")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func flagForm(_ flag: Flag) -> some View {
        Form {
            Section("伏線") {
                TextField(
                    "タイトル",
                    text: flagBinding(flag.id, \.title, fallback: "")
                )
                .textInputAutocapitalization(.never)

                Toggle(
                    "回収済み",
                    isOn: flagBinding(flag.id, \.isResolved, fallback: false)
                )

                Picker(
                    "張った章",
                    selection: flagBinding(flag.id, \.plantedChapterID, fallback: nil)
                ) {
                    chapterPickerOptions()
                }

                Picker(
                    "回収章",
                    selection: flagBinding(flag.id, \.resolvedChapterID, fallback: nil)
                ) {
                    chapterPickerOptions()
                }
            }

            Section("メモ") {
                TextEditor(text: flagBinding(flag.id, \.note, fallback: ""))
                    .frame(minHeight: 160)
                    .accessibilityLabel("伏線のメモ")
            }

            Section {
                Button("伏線を削除", role: .destructive) {
                    requestDeletion(.flag(flag.id), displayTitle: flag.title)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("伏線")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func chapterPickerOptions() -> some View {
        Text("章未設定")
            .tag(nil as ChapterID?)
        ForEach(store.document.chapters) { chapter in
            Text(chapter.title.isEmpty ? "名称未設定の章" : chapter.title)
                .tag(chapter.id as ChapterID?)
        }
    }

    private func plotCardBinding<Value>(
        _ id: PlotCardID,
        _ keyPath: WritableKeyPath<PlotCard, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                store.document.plotCards.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                guard var card = store.document.plotCards.first(where: { $0.id == id }) else { return }
                guard let expectedSession else { return }
                card[keyPath: keyPath] = newValue
                _ = store.updatePlotCard(card, expectedSession: expectedSession)
            }
        )
    }

    private func flagBinding<Value>(
        _ id: FlagID,
        _ keyPath: WritableKeyPath<Flag, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                store.document.flags.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                guard var flag = store.document.flags.first(where: { $0.id == id }) else { return }
                guard let expectedSession else { return }
                flag[keyPath: keyPath] = newValue
                _ = store.updateFlag(flag, expectedSession: expectedSession)
            }
        )
    }

    private func requestDeletion(_ target: IOSPlotSelection, displayTitle: String) {
        guard let expectedSession else { return }
        deletionRequest = IOSPlotItemDeletionRequest(
            expectedSession: expectedSession,
            target: target,
            displayTitle: displayTitle
        )
    }

    private func performDeletion(_ request: IOSPlotItemDeletionRequest) {
        let didDelete = switch request.target {
        case let .card(id):
            store.deletePlotCard(id: id, expectedSession: request.expectedSession)
        case let .flag(id):
            store.deleteFlag(id: id, expectedSession: request.expectedSession)
        }
        guard didDelete else { return }
        onDeletion()
        if dismissAfterDeletion {
            dismiss()
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("項目が選択されていません", systemImage: "rectangle.stack")
        } description: {
            Text("一覧から編集するプロットカードまたは伏線を選んでください。")
        }
    }

    private var deletionRequestIsPresented: Binding<Bool> {
        Binding(
            get: { deletionRequest != nil },
            set: { isPresented in
                if !isPresented {
                    deletionRequest = nil
                }
            }
        )
    }
}

private struct IOSPlotItemDeletionRequest: Identifiable {
    let id = UUID()
    let expectedSession: IOSDocumentSessionToken
    let target: IOSPlotSelection
    let displayTitle: String

    var title: String {
        switch target {
        case .card:
            "プロットカードを削除しますか？"
        case .flag:
            "伏線を削除しますか？"
        }
    }

    var message: String {
        let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "「\(trimmedTitle.isEmpty ? "名称未設定" : trimmedTitle)」を削除します。"
    }
}
