import AppKit
import NovelCore
import SwiftUI

struct AttachmentListView: View {
    @Environment(AppState.self) private var appState

    @Binding var selection: String?

    @State private var attachmentPendingDeletion: Attachment?
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
                List(selection: $selection) {
                    ForEach(appState.attachments) { attachment in
                        AttachmentRow(attachment: attachment)
                            .tag(attachment.fileName)
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
                }
                .overlay {
                    if appState.attachments.isEmpty {
                        ContentUnavailableView(
                            "資料がありません",
                            systemImage: "paperclip",
                            description: Text("ツールバーまたは資料メニューから取り込めます。")
                        )
                    }
                }
                .workbenchGlassOutlineStyle()
            }
        }
        .onDeleteCommand {
            guard let attachment = selectedAttachment else { return }
            attachmentPendingDeletion = attachment
        }
        .task {
            await appState.reloadAttachments()
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

    private var selectedAttachment: Attachment? {
        guard let selection else { return nil }
        return appState.attachments.first { $0.fileName == selection }
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
    private func delete(_ attachment: Attachment) async {
        if await appState.deleteAttachment(attachment) {
            if selection == attachment.fileName {
                selection = nil
            }
            operationMessage = OperationMessage(title: "削除しました", body: attachment.fileName)
        } else {
            operationMessage = OperationMessage(title: "削除できませんでした", body: "資料の削除に失敗しました。")
        }
    }
}

struct AttachmentDetailView: View {
    @Environment(AppState.self) private var appState

    let fileName: String?

    var body: some View {
        if let attachment = selectedAttachment {
            Form {
                LabeledContent("ファイル名", value: attachment.fileName)
                LabeledContent("サイズ", value: ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                if let url = appState.attachmentPreviewURL(for: attachment) {
                    LabeledContent("場所", value: url.path)
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .workbenchGlassChromeStyle()
        } else {
            ContentUnavailableView(
                "資料が選択されていません",
                systemImage: "paperclip",
                description: Text("左の一覧から資料を選択してください。")
            )
        }
    }

    private var selectedAttachment: Attachment? {
        guard let fileName else { return nil }
        return appState.attachments.first { $0.fileName == fileName }
    }
}
