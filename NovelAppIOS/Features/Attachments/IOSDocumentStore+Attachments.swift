import Foundation
import NovelCore

extension IOSDocumentStore {
    var supportsAttachments: Bool {
        attachmentManager != nil
    }

    @discardableResult
    func refreshAttachments(expectedSession: IOSDocumentSessionToken) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  validateCurrentDocumentSession(expectedSession),
                  let attachmentManager else { return false }
            let packageURL = documentURL

            do {
                let refreshed = try await saveCoordinator.performExclusive {
                    try await attachmentManager.listAttachments(in: packageURL)
                }
                guard validateCurrentDocumentSession(expectedSession) else { return false }
                replaceAttachments(refreshed)
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
                  let attachmentManager,
                  synchronizeActiveEditorForAttachmentMutation(expectedSession: expectedSession) else { return nil }
            let packageURL = documentURL
            let previousAttachments = attachments
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard await saveCoordinator.saveNow() else {
                operationErrorMessage = "保存に失敗したため、資料を取り込めませんでした。"
                return nil
            }
            guard validateCurrentDocumentSession(expectedSession) else { return nil }

            do {
                let result = try await saveCoordinator.performExclusive {
                    let added = try await attachmentManager.addAttachment(from: sourceURL, to: packageURL)
                    let refreshed = try? await attachmentManager.listAttachments(in: packageURL)
                    let fallback = Self.attachmentsByAdding(added, to: previousAttachments)
                    return (added, refreshed ?? fallback)
                }
                guard validateCurrentDocumentSession(expectedSession) else { return nil }
                replaceAttachments(result.1)
                return result.0
            } catch {
                operationErrorMessage = "資料を取り込めませんでした。外部の原本は変更していません。"
                return nil
            }
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
                  let attachmentManager,
                  synchronizeActiveEditorForAttachmentMutation(expectedSession: attachmentSession) else { return false }
            let packageURL = documentURL
            let previousAttachments = attachments

            guard await saveCoordinator.saveNow() else {
                operationErrorMessage = "保存に失敗したため、資料を削除できませんでした。"
                return false
            }
            guard validateCurrentDocumentSession(attachmentSession) else { return false }

            do {
                let refreshed = try await saveCoordinator.performExclusive {
                    try await attachmentManager.deleteAttachment(named: attachment.fileName, from: packageURL)
                    return try? await attachmentManager.listAttachments(in: packageURL)
                }
                guard validateCurrentDocumentSession(attachmentSession) else { return false }
                replaceAttachments(refreshed ?? previousAttachments.filter { $0.id != attachment.id })
                return true
            } catch {
                operationErrorMessage = "資料を削除できませんでした。現在の作品は変更していません。"
                return false
            }
        }
    }

    func attachmentPreviewURL(
        for attachment: Attachment,
        expectedSession: IOSDocumentSessionToken
    ) -> URL? {
        guard matchesCurrentDocumentSession(expectedSession),
              attachments.contains(where: { $0.id == attachment.id }),
              let attachmentManager else { return nil }
        return attachmentManager.attachmentURL(named: attachment.fileName, in: documentURL)
    }

    func loadAttachmentsForInstall(at packageURL: URL) async throws -> [Attachment] {
        guard let attachmentManager else { return [] }
        return try await attachmentManager.listAttachments(in: packageURL)
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

    private static func attachmentsByAdding(
        _ attachment: Attachment,
        to attachments: [Attachment]
    ) -> [Attachment] {
        var updated = attachments.filter { $0.id != attachment.id }
        updated.append(attachment)
        return updated.sorted {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }
}
