import NovelCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct IOSReferencesFeatureView: View {
    let store: IOSDocumentStore
    let expectedSession: IOSDocumentSessionToken?

    @State private var selection: String?

    init(store: IOSDocumentStore) {
        self.store = store
        expectedSession = store.currentDocumentSessionToken
    }

    var body: some View {
        IOSReferencesOutlineView(
            store: store,
            selection: $selection,
            expectedSession: expectedSession,
            usesNavigationLinks: true
        )
    }
}

struct IOSReferencesOutlineView: View {
    let store: IOSDocumentStore
    @Binding var selection: String?
    let expectedSession: IOSDocumentSessionToken?
    let usesNavigationLinks: Bool

    @State private var isFileImporterPresented = false
    @State private var deletionRequest: IOSAttachmentDeletionRequest?

    var body: some View {
        Group {
            if store.supportsAttachments {
                List {
                    ForEach(store.attachments) { attachment in
                        attachmentRow(attachment)
                    }
                    .onDelete(perform: requestDeletion)
                }
                .overlay {
                    if store.attachments.isEmpty {
                        ContentUnavailableView {
                            Label("資料がありません", systemImage: "paperclip")
                        } description: {
                            Text("右上の取り込みボタンから資料を追加できます。")
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("資料を管理できません", systemImage: "paperclip")
                } description: {
                    Text("現在の保存先では資料添付を利用できません。")
                }
            }
        }
        .navigationTitle("資料")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("資料を取り込む…", systemImage: "plus")
                }
                .disabled(!store.supportsAttachments || expectedSession == nil)
                .accessibilityIdentifier("ios.references.import")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task(id: expectedSession) {
            guard let expectedSession else { return }
            _ = await store.refreshAttachments(expectedSession: expectedSession)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onCompletion: importAttachment
        )
        .confirmationDialog(
            "資料を削除しますか？",
            isPresented: deletionRequestIsPresented,
            presenting: deletionRequest
        ) { request in
            Button("削除", role: .destructive) {
                Task {
                    let didDelete = await store.deleteAttachment(
                        request.attachment,
                        expectedSession: request.expectedSession
                    )
                    if didDelete, selection == request.attachment.id {
                        selection = nil
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.attachment.fileName)」を削除します。")
        }
    }

    @ViewBuilder
    private func attachmentRow(_ attachment: Attachment) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                IOSReferenceDetailView(
                    store: store,
                    fileName: attachment.fileName,
                    expectedSession: expectedSession,
                    dismissAfterDeletion: true
                )
            } label: {
                IOSAttachmentRow(attachment: attachment)
            }
        } else {
            Button {
                selection = attachment.fileName
            } label: {
                IOSAttachmentRow(attachment: attachment)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == attachment.fileName ? .isSelected : [])
        }
    }

    private func requestDeletion(at offsets: IndexSet) {
        guard let expectedSession else { return }
        let attachments = offsets.compactMap { index in
            store.attachments.indices.contains(index) ? store.attachments[index] : nil
        }
        guard let attachment = attachments.first else { return }
        deletionRequest = IOSAttachmentDeletionRequest(
            expectedSession: expectedSession,
            attachment: attachment
        )
    }

    private func importAttachment(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first, let expectedSession else { return }
            Task {
                let attachment = await store.importAttachment(
                    from: url,
                    expectedSession: expectedSession
                )
                if let attachment {
                    selection = attachment.fileName
                }
            }
        case .failure:
            store.operationErrorMessage = "資料を選択できませんでした。現在の作品は変更していません。"
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

struct IOSReferenceDetailView: View {
    let store: IOSDocumentStore
    let fileName: String?
    let expectedSession: IOSDocumentSessionToken?
    var dismissAfterDeletion = false
    var onDeletion: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    @State private var deletionRequest: IOSAttachmentDeletionRequest?

    var body: some View {
        Group {
            if let attachment = selectedAttachment {
                attachmentForm(attachment)
            } else {
                ContentUnavailableView {
                    Label("資料が選択されていません", systemImage: "paperclip")
                } description: {
                    Text("一覧から確認する資料を選んでください。")
                }
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            "資料を削除しますか？",
            isPresented: deletionRequestIsPresented,
            presenting: deletionRequest
        ) { request in
            Button("削除", role: .destructive) {
                Task {
                    let didDelete = await store.deleteAttachment(
                        request.attachment,
                        expectedSession: request.expectedSession
                    )
                    guard didDelete else { return }
                    onDeletion()
                    if dismissAfterDeletion {
                        dismiss()
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.attachment.fileName)」を削除します。")
        }
    }

    private func attachmentForm(_ attachment: Attachment) -> some View {
        Form {
            Section("資料") {
                LabeledContent("ファイル名", value: attachment.fileName)
                LabeledContent(
                    "サイズ",
                    value: ByteCountFormatter.string(
                        fromByteCount: attachment.byteCount,
                        countStyle: .file
                    )
                )
            }

            Section {
                Button {
                    guard let expectedSession else { return }
                    previewURL = store.attachmentPreviewURL(
                        for: attachment,
                        expectedSession: expectedSession
                    )
                } label: {
                    Label("資料をプレビュー", systemImage: "eye")
                }
                .disabled(expectedSession == nil)

                if let shareURL = shareURL(for: attachment) {
                    ShareLink(item: shareURL) {
                        Label("資料を共有…", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section {
                Button("資料を削除", role: .destructive) {
                    guard let expectedSession else { return }
                    deletionRequest = IOSAttachmentDeletionRequest(
                        expectedSession: expectedSession,
                        attachment: attachment
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(attachment.fileName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shareURL(for attachment: Attachment) -> URL? {
        guard let expectedSession else { return nil }
        return store.attachmentPreviewURL(
            for: attachment,
            expectedSession: expectedSession
        )
    }

    private var selectedAttachment: Attachment? {
        guard let fileName else { return nil }
        return store.attachments.first(where: { $0.fileName == fileName })
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

private struct IOSAttachmentRow: View {
    let attachment: Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attachment.fileName)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(sizeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachment.fileName)
        .accessibilityValue(sizeDescription)
    }

    private var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
    }
}

private struct IOSAttachmentDeletionRequest: Identifiable {
    let id = UUID()
    let expectedSession: IOSDocumentSessionToken
    let attachment: Attachment
}
