import Foundation
import NovelCore
import NovelSyncV2
import NovelThumbnail

/// 添付はv2 snapshotの一部としてSQLiteへ保存する。`.novelpkg`のcodecは、
/// この画面から明示的に書き出す／取り込む場合にだけ呼び出される。
extension AppState {
    func reloadAttachments(expectedSession: DocumentSessionToken? = nil) async {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        attachmentPreviewURLs.removeAll()
        attachments = snapshotSyncV2Attachments.map {
            Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
        }
    }

    @discardableResult
    func addAttachment(from sourceURL: URL, expectedSession: DocumentSessionToken? = nil) async -> Attachment? {
        var added: Attachment?
        let succeeded = await performSnapshotDataMutation(expectedSession: expectedSession) {
            added = await self.addAttachmentWithinSaveBoundary(from: sourceURL, expectedSession: expectedSession)
            return added != nil
        }
        return succeeded ? added : nil
    }

    @discardableResult
    func deleteAttachment(_ attachment: Attachment, expectedSession: DocumentSessionToken? = nil) async -> Bool {
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
        expectedSession: DocumentSessionToken? = nil,
        operation: () async -> Bool
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
        expectedSession: DocumentSessionToken? = nil
    ) async -> Attachment? {
        guard permitsMutation(expectedSession: expectedSession) else { return nil }
        do {
            let bytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let sourceName = sourceURL.lastPathComponent.isEmpty ? "資料" : sourceURL.lastPathComponent
            let originalName = ThumbnailOwner.isReserved(sourceName) ? "資料-" + sourceName : sourceName
            let usedNames = Set(snapshotSyncV2Attachments.map(\.fileName))
            let fileName = Self.uniqueAttachmentName(originalName, usedNames: usedNames)
            let previousPayloads = snapshotSyncV2Attachments
            let previousRecords = attachments
            let previousPreviews = attachmentPreviewURLs
            let item = SyncAttachment(
                attachmentId: UUID(),
                fileName: fileName,
                bytes: bytes
            )
            snapshotSyncV2Attachments.append(item)
            attachmentPreviewURLs.removeValue(forKey: fileName)
            attachments.append(Attachment(fileName: fileName, byteCount: Int64(bytes.count)))
            guard await checkpointSnapshotSyncV2(document, reason: .navigation) else {
                snapshotSyncV2Attachments = previousPayloads
                attachments = previousRecords
                attachmentPreviewURLs = previousPreviews
                return nil
            }
            return Attachment(fileName: fileName, byteCount: Int64(bytes.count))
        } catch {
            return nil
        }
    }

    @discardableResult
    func deleteAttachmentWithinSaveBoundary(
        _ attachment: Attachment,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        let previousPayloads = snapshotSyncV2Attachments
        let previousRecords = attachments
        let previousPreviews = attachmentPreviewURLs
        let originalCount = snapshotSyncV2Attachments.count
        snapshotSyncV2Attachments.removeAll { $0.fileName == attachment.fileName }
        guard snapshotSyncV2Attachments.count != originalCount else { return false }
        let removedPreview = attachmentPreviewURLs.removeValue(forKey: attachment.fileName)
        attachments.removeAll { $0.fileName == attachment.fileName }
        let saved = await checkpointSnapshotSyncV2(document, reason: .navigation)
        guard saved else {
            snapshotSyncV2Attachments = previousPayloads
            attachments = previousRecords
            attachmentPreviewURLs = previousPreviews
            return false
        }
        if let removedPreview {
            try? fileManager.removeItem(at: removedPreview)
        }
        return true
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

    private static func uniqueAttachmentName(_ name: String, usedNames: Set<String>) -> String {
        guard usedNames.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var index = 2
        var candidate = "\(stem) (\(index))\(suffix)"
        while usedNames.contains(candidate) {
            index += 1
            candidate = "\(stem) (\(index))\(suffix)"
        }
        return candidate
    }
}
