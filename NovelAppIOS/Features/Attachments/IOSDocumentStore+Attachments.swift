import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    var supportsAttachments: Bool {
        snapshotSyncV2Application != nil
    }

    @discardableResult
    func refreshAttachments(expectedSession: WorkspaceSessionToken) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  validateCurrentDocumentSession(expectedSession) else { return false }

            guard let application = snapshotSyncV2Application,
                  let workID = syncV2ActiveWorkID else { return false }
            let expectedAccountScope = snapshotSyncV2AccountScope
            do {
                let opened = try await application.openLocal(workID: workID)
                guard !syncV2AccountTransitionInProgress,
                      matchesSyncAccount(expectedAccountScope),
                      syncV2ActiveWorkID == workID,
                      opened.workID == workID,
                      validateCurrentDocumentSession(expectedSession) else { return false }
                return replaceV2Attachments(opened.attachments)
            } catch {
                operationErrorMessage = "資料一覧を読み込めませんでした。現在の作品は変更していません。"
                return false
            }
        }
    }

    @discardableResult
    func importAttachment(
        from sourceURL: URL,
        expectedSession: WorkspaceSessionToken,
        expectedAccountScope: WorkspaceAccountScope? = nil
    ) async -> Attachment? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  !syncV2AccountTransitionInProgress, !Task.isCancelled,
                  expectedAccountScope == nil || matchesSyncAccount(expectedAccountScope),
                  validateCurrentDocumentSession(expectedSession),
                  synchronizeActiveEditorForAttachmentMutation(expectedSession: expectedSession) else { return nil }

            guard snapshotSyncV2Application != nil,
                  let expectedWorkID = syncV2ActiveWorkID else { return nil }
            let expectedAccountScope = snapshotSyncV2AccountScope
            return await importV2Attachment(
                from: sourceURL,
                expectedSession: expectedSession,
                expectedWorkID: expectedWorkID,
                expectedAccountScope: expectedAccountScope
            )
        }
    }

    @discardableResult
    func deleteAttachment(
        _ attachment: Attachment,
        expectedSession: WorkspaceSessionToken,
        expectedAccountScope: WorkspaceAccountScope? = nil
    ) async -> Bool {
        let attachmentSession = expectedSession
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  !syncV2AccountTransitionInProgress, !Task.isCancelled,
                  expectedAccountScope == nil || matchesSyncAccount(expectedAccountScope),
                  validateCurrentDocumentSession(attachmentSession),
                  attachments.contains(where: { $0.id == attachment.id }),
                  synchronizeActiveEditorForAttachmentMutation(expectedSession: attachmentSession) else { return false }

            guard snapshotSyncV2Application != nil,
                  let expectedWorkID = syncV2ActiveWorkID else { return false }
            let expectedAccountScope = snapshotSyncV2AccountScope
            return await deleteV2Attachment(
                attachment,
                expectedSession: attachmentSession,
                expectedWorkID: expectedWorkID,
                expectedAccountScope: expectedAccountScope
            )
        }
    }

    func attachmentPreviewURL(
        for attachment: Attachment,
        expectedSession: WorkspaceSessionToken
    ) -> URL? {
        guard matchesCurrentDocumentSession(expectedSession),
              attachments.contains(where: { $0.id == attachment.id }) else { return nil }
        guard let bytes = workspaceAttachments[attachment.fileName]?.bytes else { return nil }
        let safeName = attachment.fileName.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("FUMINIWA-Attachment-\(UUID().uuidString)-\(safeName)")
        return (try? bytes.write(to: url, options: .atomic)) == nil ? nil : url
    }

    @discardableResult
    func adoptV2AttachmentRecords(_ values: [SyncAttachment]) -> Bool {
        replaceV2Attachments(values)
    }

    func synchronizeActiveEditorForAttachmentMutation(
        expectedSession: WorkspaceSessionToken
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

    @discardableResult
    private func replaceV2Attachments(_ values: [SyncAttachment]) -> Bool {
        guard validateV2AttachmentRecords(values) else {
            operationErrorMessage = "資料一覧が壊れているため、作品を変更していません。"
            snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
            return false
        }
        guard let replacement = WorkspaceAttachmentSet(values) else { return false }
        installWorkspaceAttachments(replacement)
        return true
    }

    func installWorkspaceAttachments(_ replacement: WorkspaceAttachmentSet) {
        workspaceAttachments = replacement
        replaceAttachments(replacement.attachments)
    }

    func validateV2AttachmentRecords(_ values: [SyncAttachment]) -> Bool {
        WorkspaceAttachmentSet(values) != nil
    }

    private func importV2Attachment(
        from sourceURL: URL,
        expectedSession: WorkspaceSessionToken,
        expectedWorkID: WorkID,
        expectedAccountScope: WorkspaceAccountScope
    ) async -> Attachment? {
        guard snapshotSyncV2Application != nil,
              !syncV2AccountTransitionInProgress,
              syncV2ActiveWorkID == expectedWorkID,
              matchesSyncAccount(expectedAccountScope),
              validateCurrentDocumentSession(expectedSession) else { return nil }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bytes = try Data(contentsOf: sourceURL)
            let item = await attachmentCommands(
                beforeFailure: "本文を端末へ保存できないため、資料の取り込みを中止しました。",
                afterFailure: "資料は保存しましたが、途中の本文変更を端末へ保存できませんでした。",
                checkpointFailure: "資料を取り込めませんでした。外部の原本は変更していません。"
            ).add(bytes, named: sourceURL.lastPathComponent, style: .hyphen, context: operationContext)
            return item.map { Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount)) }
        } catch {
            operationErrorMessage = "資料を取り込めませんでした。外部の原本は変更していません。"
            return nil
        }
    }

    private func deleteV2Attachment(
        _ attachment: Attachment,
        expectedSession: WorkspaceSessionToken,
        expectedWorkID: WorkID,
        expectedAccountScope: WorkspaceAccountScope
    ) async -> Bool {
        guard snapshotSyncV2Application != nil,
              !syncV2AccountTransitionInProgress,
              syncV2ActiveWorkID == expectedWorkID,
              matchesSyncAccount(expectedAccountScope),
              validateCurrentDocumentSession(expectedSession) else { return false }
        return await attachmentCommands(
            beforeFailure: "本文を端末へ保存できないため、資料の削除を中止しました。",
            afterFailure: "資料は削除しましたが、途中の本文変更を端末へ保存できませんでした。",
            checkpointFailure: "資料を削除できませんでした。現在の作品は変更していません。"
        ).delete(named: attachment.fileName, context: operationContext)
    }

    /// Called inside the document gate, after the platform editor synchronization.
    func attachmentCommands(beforeFailure: String? = nil, afterFailure: String? = nil,
                            checkpointFailure: String, requiresPostSave: Bool = false) -> WorkspaceAttachmentCommands {
        let expected = operationContext
        return WorkspaceAttachmentCommands(host: self, boundary: { operation in
            let result = await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true, operation)
            switch result {
            case .saveFailedBeforeOperation:
                if let beforeFailure {
                    self.operationErrorMessage = beforeFailure
                }
                return false
            case let .completed(saved, flushed):
                if saved, !flushed, let afterFailure {
                    self.operationErrorMessage = afterFailure
                }
                return saved && (!requiresPostSave || flushed)
            }
        }, checkpoint: { document, candidate in
            guard let application = self.snapshotSyncV2Application, let work = expected.workID,
                  self.currentV2Attachments() != nil else { return false }
            do {
                _ = try await application.checkpoint(workID: work, document: document, reason: .explicit,
                                                     documentCreatedAt: self.documentCreatedAt, attachments: candidate.records)
                return true
            } catch {
                self.operationErrorMessage = checkpointFailure
                return false
            }
        })
    }

    func currentV2Attachments() -> [SyncAttachment]? {
        // A metadata-only legacy install must still fail closed instead of saving missing bytes.
        guard attachments == workspaceAttachments.attachments else { return nil }
        return workspaceAttachments.records
    }
}
