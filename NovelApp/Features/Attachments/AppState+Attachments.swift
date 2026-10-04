import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

/// 添付はv2 snapshotの一部としてSQLiteへ保存する。`.novelpkg`のcodecは、
/// この画面から明示的に書き出す／取り込む場合にだけ呼び出される。
extension AppState {
    func reloadAttachments(expectedSession: WorkspaceSessionToken? = nil) async {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        attachmentPreviewURLs.removeAll()
        attachments = snapshotSyncV2Attachments.map {
            Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
        }
    }

    @discardableResult
    func addAttachment(from sourceURL: URL, expectedSession: WorkspaceSessionToken? = nil) async -> Attachment? {
        var added: Attachment?
        let succeeded = await performSnapshotDataMutation(expectedSession: expectedSession) {
            added = await self.addAttachmentWithinSaveBoundary(from: sourceURL, expectedSession: expectedSession)
            return added != nil
        }
        return succeeded ? added : nil
    }

    @discardableResult
    func deleteAttachment(_ attachment: Attachment, expectedSession: WorkspaceSessionToken? = nil) async -> Bool {
        await performSnapshotDataMutation(expectedSession: expectedSession) {
            await self.deleteAttachmentWithinSaveBoundary(attachment, expectedSession: expectedSession)
        }
    }

    func saveExplicitSnapshot() async -> Bool {
        await performSnapshotDataMutation {
            await self.checkpointSnapshotSyncV2(self.document, reason: .explicit)
        }
    }

    func performSnapshotDataMutation(
        expectedSession: WorkspaceSessionToken? = nil,
        operation: @MainActor () async -> Bool
    ) async -> Bool {
        let session = expectedSession ?? documentSessionToken
        let account = snapshotSyncV2AccountScopeToken
        return await documentOperationGate.perform {
            guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                  self.permitsDocumentInteraction,
                  self.editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { self.editorCommandSession.resumeAfterDocumentTransition() }
            let result = await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                      self.permitsDocumentInteraction, !Task.isCancelled else { return false }
                return await operation()
            }
            guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account else { return false }
            if case let .completed(saved, savedAfterOperation) = result {
                return saved && savedAfterOperation
            }
            return false
        }
    }

    @discardableResult
    func addAttachmentWithinSaveBoundary(
        from sourceURL: URL,
        expectedSession: WorkspaceSessionToken? = nil
    ) async -> Attachment? {
        guard permitsMutation(expectedSession: expectedSession) else { return nil }
        do {
            let bytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let item = await attachmentCommandsWithinSaveBoundary(reason: .navigation).add(
                bytes, named: sourceURL.lastPathComponent, style: .parentheses, context: operationContext
            )
            return item.map { Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount)) }
        } catch { return nil }
    }

    @discardableResult
    func deleteAttachmentWithinSaveBoundary(
        _ attachment: Attachment,
        expectedSession: WorkspaceSessionToken? = nil
    ) async -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        let preview = attachmentPreviewURLs[attachment.fileName]
        let saved = await attachmentCommandsWithinSaveBoundary(reason: .navigation).delete(
            named: attachment.fileName, context: operationContext
        )
        if saved, let preview {
            try? fileManager.removeItem(at: preview)
        }
        return saved
    }

    func installWorkspaceAttachments(_ replacement: WorkspaceAttachmentSet) {
        let changed = workspaceAttachments.records.filter { replacement[$0.fileName] != $0 }.map(\.fileName)
        for name in changed {
            attachmentPreviewURLs.removeValue(forKey: name)
        }
        workspaceAttachments = replacement
        attachments = replacement.attachments
    }

    func attachmentCommandsWithinSaveBoundary(reason: SyncV2CheckpointReason) -> WorkspaceAttachmentCommands {
        WorkspaceAttachmentCommands(host: self, boundary: { await $0() }, checkpoint: { document, candidate in
            await self.checkpointSnapshotSyncV2(document, reason: reason, attachments: candidate.records)
        })
    }

    /// Materialize the SQLite resource bytes into a disposable URL for AppKit
    /// previews. This URL is never used as document identity or save authority.
    func attachmentPreviewURL(for attachment: Attachment) -> URL? {
        guard let resource = snapshotSyncV2Attachments.first(where: { $0.fileName == attachment.fileName }) else {
            return nil
        }
        if let cached = attachmentPreviewURLs[attachment.fileName],
           fileManager.fileExists(atPath: cached.path) {
            return cached
        }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("FUMINIWA-v2-attachment-previews", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let extensionPart = URL(fileURLWithPath: resource.fileName).pathExtension
            let previewName = extensionPart.isEmpty
                ? resource.attachmentId.uuidString
                : "\(resource.attachmentId.uuidString).\(extensionPart)"
            let previewURL = directory.appendingPathComponent(previewName)
            try resource.bytes.write(to: previewURL, options: .atomic)
            attachmentPreviewURLs[attachment.fileName] = previewURL
            return previewURL
        } catch {
            return nil
        }
    }
}
