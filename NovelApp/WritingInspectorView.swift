import AppKit
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

struct WritingInspectorView: View {
    @Environment(AppState.self) private var appState

    @Binding var selectedTab: WritingInspectorTab
    @Binding var memo: String
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("インスペクタ", selection: $selectedTab) {
                Label("章メモ", systemImage: "note.text")
                    .tag(WritingInspectorTab.memo)
                Label("この章", systemImage: "doc.text.magnifyingglass")
                    .tag(WritingInspectorTab.chapter)
                Label("資料", systemImage: "paperclip")
                    .tag(WritingInspectorTab.attachments)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            Divider()

            switch selectedTab {
            case .memo:
                if appState.selectedChapter == nil {
                    ContentUnavailableView(
                        "章が選択されていません",
                        systemImage: "note.text",
                        description: Text("左のサイドバーから章を選択してください。")
                    )
                } else {
                    TextEditor(text: $memo)
                        .font(.body)
                        .padding(8)
                }
            case .chapter:
                ChapterContextView(
                    onOpenCharacter: onOpenCharacter,
                    onOpenPlotCard: onOpenPlotCard
                )
            case .attachments:
                AttachmentInspectorView()
            }
        }
        .frame(minWidth: 280)
    }
}

private struct ChapterContextView: View {
    @Environment(AppState.self) private var appState

    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    var body: some View {
        List {
            Section("プロットカード") {
                let cards = chapterPlotCards
                if cards.isEmpty {
                    ContentUnavailableView(
                        "プロットカードがありません",
                        systemImage: "rectangle.stack",
                        description: Text("プロットモードでこの章のカードを追加できます。")
                    )
                } else {
                    ForEach(cards) { card in
                        Button {
                            onOpenPlotCard(card.id)
                        } label: {
                            PlotCardRow(card: card, chapterTitle: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("登場キャラクター") {
                let characters = appearingCharacters
                if characters.isEmpty {
                    ContentUnavailableView(
                        "登場キャラクターがありません",
                        systemImage: "person.2",
                        description: Text("本文にキャラクター名かふりがなが含まれると表示されます。")
                    )
                } else {
                    ForEach(characters) { character in
                        Button {
                            onOpenCharacter(character.id)
                        } label: {
                            CharacterRow(character: character)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var chapterPlotCards: [PlotCard] {
        guard let chapterID = appState.selection else { return [] }
        return appState.document.plotCards.filter { $0.chapterID == chapterID }
    }

    private var appearingCharacters: [NovelCore.Character] {
        guard let chapter = appState.selectedChapter else { return [] }
        return appState.document.characters.filter { character in
            CharacterAppearanceDetector.appearances(
                for: character,
                in: NovelDocument(
                    id: appState.document.id,
                    title: appState.document.title,
                    chapters: [chapter],
                    characters: [],
                    plotCards: [],
                    flags: []
                )
            ).isEmpty == false
        }
    }
}

struct AttachmentInspectorView: View {
    @Environment(AppState.self) private var appState

    @State private var attachmentPendingDeletion: Attachment?
    @State private var isImportingAttachment = false
    @State private var operationMessage: OperationMessage?

    var body: some View {
        VStack(spacing: 0) {
            if !appState.supportsAttachments {
                ContentUnavailableView(
                    "資料添付に対応していません",
                    systemImage: "paperclip",
                    description: Text("この保存先では資料を管理できません。")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(appState.attachments) { attachment in
                    AttachmentRow(attachment: attachment)
                        .contextMenu {
                            Button {
                                revealInFinder(attachment)
                            } label: {
                                Label("Finderで表示", systemImage: "folder")
                            }

                            Button(role: .destructive) {
                                attachmentPendingDeletion = attachment
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
                .overlay {
                    if appState.attachments.isEmpty {
                        ContentUnavailableView(
                            "資料がありません",
                            systemImage: "paperclip",
                            description: Text("下の資料を取り込むボタンから資料を追加できます。")
                        )
                    }
                }

                Divider()

                HStack {
                    Button {
                        isImportingAttachment = true
                    } label: {
                        Label("資料を取り込む…", systemImage: "plus")
                    }

                    Button {
                        if let attachment = appState.attachments.first {
                            revealInFinder(attachment)
                        }
                    } label: {
                        Label("Finderで表示", systemImage: "folder")
                    }
                    .disabled(appState.attachments.isEmpty)

                    Spacer()
                }
                .padding(8)
            }
        }
        .task {
            await appState.reloadAttachments()
        }
        .fileImporter(
            isPresented: $isImportingAttachment,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task {
                await importAttachment(from: result)
            }
        }
        .confirmationDialog(
            "資料を削除しますか？",
            isPresented: attachmentDeletionDialogIsPresented,
            presenting: attachmentPendingDeletion
        ) { attachment in
            Button("削除", role: .destructive) {
                Task { await delete(attachment) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { attachment in
            Text("「\(attachment.fileName)」を削除します。")
        }
        .alert(item: $operationMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("閉じる")))
        }
    }

    private var attachmentDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { attachmentPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    attachmentPendingDeletion = nil
                }
            }
        )
    }

    private func revealInFinder(_ attachment: Attachment) {
        guard let url = appState.attachmentPreviewURL(for: attachment) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    private func importAttachment(from result: Result<[URL], Error>) async {
        do {
            guard let sourceURL = try result.get().first else { return }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            if let attachment = await appState.addAttachment(from: sourceURL) {
                operationMessage = OperationMessage(title: "取り込みました", body: attachment.fileName)
            } else {
                operationMessage = OperationMessage(title: "取り込めませんでした", body: "資料の追加に失敗しました。")
            }
        } catch {
            operationMessage = OperationMessage(title: "取り込めませんでした", body: String(describing: error))
        }
    }

    @MainActor
    private func delete(_ attachment: Attachment) async {
        if await appState.deleteAttachment(attachment) {
            operationMessage = OperationMessage(title: "削除しました", body: attachment.fileName)
        } else {
            operationMessage = OperationMessage(title: "削除できませんでした", body: "資料の削除に失敗しました。")
        }
    }
}
