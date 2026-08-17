import Foundation
import NovelCore
import NovelSyncV2

extension IOSDocumentStore {
    var supportsAttachments: Bool {
        snapshotSyncV2Application != nil
    }

    @discardableResult
    func refreshAttachments(expectedSession: IOSDocumentSessionToken) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  validateCurrentDocumentSession(expectedSession) else { return false }

            guard let application = snapshotSyncV2Application,
                  let workID = syncV2ActiveWorkID else { return false }
            do {
                let opened = try await application.open(workID: workID)
                guard validateCurrentDocumentSession(expectedSession) else { return false }
                replaceV2Attachments(opened.attachments)
                return true
            } catch {
                operationErrorMessage = "資料一覧を読み込めませんでした。現在の作品は変更していません。"
                return false
            }
        }
    }

    @discardableResult
    func importAttachment(
        from sourceURL: URL,
        expectedSession: IOSDocumentSessionToken
    ) async -> Attachment? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  validateCurrentDocumentSession(expectedSession),
                  synchronizeActiveEditorForAttachmentMutation(expectedSession: expectedSession) else { return nil }

            guard snapshotSyncV2Application != nil else { return nil }
            return await importV2Attachment(from: sourceURL, expectedSession: expectedSession)
        }
    }

    @discardableResult
    func deleteAttachment(
        _ attachment: Attachment,
        expectedSession: IOSDocumentSessionToken
    ) async -> Bool {
        let attachmentSession = expectedSession
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  validateCurrentDocumentSession(attachmentSession),
                  attachments.contains(where: { $0.id == attachment.id }),
                  synchronizeActiveEditorForAttachmentMutation(expectedSession: attachmentSession) else { return false }

            guard snapshotSyncV2Application != nil else { return false }
            return await deleteV2Attachment(attachment, expectedSession: attachmentSession)
        }
    }

    func attachmentPreviewURL(
        for attachment: Attachment,
        expectedSession: IOSDocumentSessionToken
    ) -> URL? {
        guard matchesCurrentDocumentSession(expectedSession),
              attachments.contains(where: { $0.id == attachment.id }) else { return nil }
        guard let bytes = syncV2AttachmentPayloads[attachment.fileName] else { return nil }
        let safeName = attachment.fileName.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("FUMINIWA-Attachment-\(UUID().uuidString)-\(safeName)")
        return (try? bytes.write(to: url, options: .atomic)) == nil ? nil : url
    }

    func adoptV2AttachmentRecords(_ values: [SyncAttachment]) {
        replaceV2Attachments(values)
    }

    private func synchronizeActiveEditorForAttachmentMutation(
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            guard validateCurrentDocumentSession(expectedSession) else { return false }
            guard let chapterID = selectedChapterID, let episodeID = selectedEpisodeID else {
                operationErrorMessage = "表示中の本文を安全に保存できないため、資料操作を中止しました。"
                return false
            }
            guard document.episode(episodeID)?.chapterID == chapterID else {
                operationErrorMessage = "表示中の本文を安全に保存できないため、資料操作を中止しました。"
                return false
            }
            updateEpisodeContent(text, chapterID: chapterID, episodeID: episodeID)
            return true
        case .compositionInProgress:
            operationErrorMessage = "日本語入力を確定してから、もう一度お試しください。"
            return false
        case .notActive:
            return true
        }
    }

    private func replaceV2Attachments(_ values: [SyncAttachment]) {
        replaceAttachments(values.map {
            Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
        })
        syncV2AttachmentPayloads = Dictionary(
            uniqueKeysWithValues: values.map { ($0.fileName, $0.bytes) }
        )
        syncV2AttachmentIDs = Dictionary(
            uniqueKeysWithValues: values.map { ($0.fileName, $0.attachmentId) }
        )
    }

    private func importV2Attachment(
        from sourceURL: URL,
        expectedSession: IOSDocumentSessionToken
    ) async -> Attachment? {
        guard let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bytes = try Data(contentsOf: sourceURL)
            let originalName = sourceURL.lastPathComponent.isEmpty ? "資料" : sourceURL.lastPathComponent
            let name = uniqueV2AttachmentName(originalName)
            let value = Attachment(fileName: name, byteCount: Int64(bytes.count))
            let previousAttachments = attachments
            let previousPayloads = syncV2AttachmentPayloads
            let previousIDs = syncV2AttachmentIDs
            replaceAttachments(previousAttachments + [value])
            syncV2AttachmentPayloads[name] = bytes
            syncV2AttachmentIDs[name] = UUID()
            do {
                _ = try await application.checkpoint(
                    workID: workID,
                    document: document,
                    reason: .explicit,
                    documentCreatedAt: documentCreatedAt,
                    attachments: currentV2AttachmentsOrThrow()
                )
            } catch {
                replaceAttachments(previousAttachments)
                syncV2AttachmentPayloads = previousPayloads
                syncV2AttachmentIDs = previousIDs
                throw error
            }
            saveState = .saved
            return value
        } catch {
            operationErrorMessage = "資料を取り込めませんでした。外部の原本は変更していません。"
            return nil
        }
    }

    private func deleteV2Attachment(
        _ attachment: Attachment,
        expectedSession: IOSDocumentSessionToken
    ) async -> Bool {
        guard let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID,
              validateCurrentDocumentSession(expectedSession) else { return false }
        let previousAttachments = attachments
        let previousPayloads = syncV2AttachmentPayloads
        let previousIDs = syncV2AttachmentIDs
        replaceAttachments(attachments.filter { $0.id != attachment.id })
        syncV2AttachmentPayloads.removeValue(forKey: attachment.fileName)
        syncV2AttachmentIDs.removeValue(forKey: attachment.fileName)
        do {
            _ = try await application.checkpoint(
                workID: workID,
                document: document,
                reason: .explicit,
                documentCreatedAt: documentCreatedAt,
                attachments: currentV2AttachmentsOrThrow()
            )
            saveState = .saved
            return true
        } catch {
            replaceAttachments(previousAttachments)
            syncV2AttachmentPayloads = previousPayloads
            syncV2AttachmentIDs = previousIDs
            operationErrorMessage = "資料を削除できませんでした。現在の作品は変更していません。"
            return false
        }
    }

    func currentV2Attachments() -> [SyncAttachment]? {
        var records: [SyncAttachment] = []
        for attachment in attachments {
            guard let bytes = syncV2AttachmentPayloads[attachment.fileName] else { return nil }
            let attachmentID: UUID
            if let existing = syncV2AttachmentIDs[attachment.fileName] {
                attachmentID = existing
            } else {
                let generated = UUID()
                syncV2AttachmentIDs[attachment.fileName] = generated
                attachmentID = generated
            }
            records.append(SyncAttachment(
                attachmentId: attachmentID,
                fileName: attachment.fileName,
                bytes: bytes
            ))
        }
        return records
    }

    private func currentV2AttachmentsOrThrow() throws -> [SyncAttachment] {
        guard let records = currentV2Attachments() else {
            operationErrorMessage = "資料の本文を読み込めないため、端末への保存を中止しました。"
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return records
    }

    private func uniqueV2AttachmentName(_ original: String) -> String {
        guard attachments.contains(where: { $0.fileName == original }) else { return original }
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if !attachments.contains(where: { $0.fileName == candidate }) {
                return candidate
            }
            index += 1
        }
    }
}
