import AppKit
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentInspectorView: View {
    @Environment(AppState.self) private var appState

    @State private var attachmentPendingDeletion: Attachment?
    @State private var isImportingAttachment = false
    @State private var operationMessage: OperationMessage?

    var body: some View {
        VStack(spacing: 0) {
            if !appState.supportsAttachments {
                ContentUnavailableView("資料添付に対応していません", systemImage: "paperclip")
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
                        ContentUnavailableView("資料がありません", systemImage: "paperclip")
                    }
                }

                Divider()

                HStack {
                    Button {
                        isImportingAttachment = true
                    } label: {
                        Label("取り込む", systemImage: "plus")
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
                .padding(10)
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
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("OK")))
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

private struct AttachmentRow: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .lineLimit(1)
                Text(byteCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
    }
}
