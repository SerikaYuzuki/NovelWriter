import NovelCore
import SwiftUI

private struct SessionBoundAttachment: Identifiable {
    var attachment: Attachment
    var session: DocumentSessionToken

    var id: String {
        attachment.id
    }
}

struct AttachmentListView: View {
    @Environment(AppState.self) private var appState

    @Binding var selection: String?

    @State private var attachmentPendingDeletion: SessionBoundAttachment?
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
                    ForEach(sessionBoundAttachments) { item in
                        AttachmentRow(attachment: item.attachment)
                            .tag(item.attachment.fileName)
                            .contextMenu {
                                Button(role: .destructive) {
                                    attachmentPendingDeletion = item
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
            attachmentPendingDeletion = SessionBoundAttachment(
                attachment: attachment,
                session: appState.documentSessionToken
            )
        }
        .task {
            await appState.reloadAttachments()
        }
        .confirmationDialog(
            "資料を削除しますか？",
            isPresented: attachmentDeletionDialogIsPresented,
            presenting: attachmentPendingDeletion
        ) { request in
            Button("削除", role: .destructive) {
                Task { await delete(request) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.attachment.fileName)」を削除します。")
        }
        .alert(item: $operationMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("閉じる")))
        }
    }

    private var selectedAttachment: Attachment? {
        guard let selection else { return nil }
        return appState.attachments.first { $0.fileName == selection }
    }

    private var sessionBoundAttachments: [SessionBoundAttachment] {
        let session = appState.documentSessionToken
        return appState.attachments.map {
            SessionBoundAttachment(attachment: $0, session: session)
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

    @MainActor
    private func delete(_ request: SessionBoundAttachment) async {
        let attachment = request.attachment
        let didDelete = await appState.deleteAttachment(attachment, expectedSession: request.session)
        guard appState.documentSessionToken == request.session else {
            operationMessage = OperationMessage(
                title: didDelete ? "元の作品から削除しました" : "削除できませんでした",
                body: "操作中に別の作品へ切り替わりました。現在の資料は変更していません。"
            )
            return
        }

        if didDelete {
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
