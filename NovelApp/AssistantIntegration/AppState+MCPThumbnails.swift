#if os(macOS)
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelThumbnail
import NovelWorkspaceUI
import NovelWritingSupport

extension AppState {
    func readMCPThumbnail(_ owner: ThumbnailOwner, validate: () throws -> Void) throws -> Data? {
        try validate()
        guard owner.exists(in: document) else { throw WritingError.changedTarget }
        let images = snapshotSyncV2Attachments.filter { $0.fileName == owner.fileName }
        guard images.count <= 1 else { throw WritingError.changedTarget }
        guard let image = images.first else { return nil }
        guard image.bytes.count <= ThumbnailEncoder.maximumBytes else { throw WritingError.invalidEdit }
        try WritingMCPThumbnailImage.validate(image.bytes, jpegOnly: true)
        return image.bytes
    }

    func applyMCPThumbnail(_ request: WritingMCPThumbnailRequest, grant: WritingGrant, application: SyncV2Application,
                           context: SyncV2WritingContext, validate: () throws -> Void) async throws -> String {
        guard grant.permits(WritingMCPThumbnailRequest.path(request.owner)),
              !grant.appendOnly else { throw WritingError.outsideGrant }
        var outcome = "prepared"
        try await withinMCPThumbnailBoundary(workID: request.edit.workId, validate: validate) {
            if let state = try await application.writingEditOutcome(request.edit, context: context) {
                outcome = state; return
            }
            guard request.edit.documentId == self.document.id,
                  request.owner.exists(in: self.document) else { throw WritingError.changedScope }
            let old = try self.currentMCPThumbnail(request.owner)
            let new = request.image.map { SyncAttachment(
                attachmentId: UUID(),
                fileName: request.owner.fileName,
                bytes: $0
            ) }
            let prepared = try WritingEdit(
                id: request.edit.id,
                workId: request.edit.workId,
                documentId: request.edit.documentId,
                changes: [.init(path: WritingMCPThumbnailRequest.path(request.owner),
                                before: Self.thumbnailValue(old),
                                after: Self.thumbnailValue(new))]
            )
            // Images exist only in this local prepared journal, never in the synchronized request record.
            let stored = WritingStoredEdit(requested: request.edit, prepared: prepared)
            let journalPayload = try WritingRecord.payload(stored)
            guard journalPayload.utf8.count <= 600_000 else { throw WritingError.invalidEdit }
            guard try await application.claimWritingEdit(request.edit, prepared: prepared, context: context) else {
                throw WritingError.alreadyApplied
            }
            try validate()
            let record = try WritingRecord(id: request.edit.id, workId: request.edit.workId, kind: "edit",
                                           key: request.edit.id.uuidString.lowercased(),
                                           payload: WritingRecord.payload(request.edit))
            try await application.appendWritingRecord(record, context: context)
            try validate()
            try await self.installMCPThumbnail(new, replacing: old, owner: request.owner, validate: validate)
            try await application.finishWritingEdit(id: request.edit.id, state: "applied", context: context)
            outcome = "applied"
            // A prepared claim survives an uncertain checkpoint; explicit Undo can recover it.
        }
        return outcome
    }

    func undoMCPThumbnail(_ id: UUID, application: SyncV2Application, context: SyncV2WritingContext,
                          validate: () throws -> Void) async throws {
        guard let work = UUID(uuidString: context.workID.description) else { throw WritingError.changedScope }
        try await withinMCPThumbnailBoundary(workID: work, validate: validate) {
            guard let journal = try await application.writingEdit(id: id, context: context),
                  ["applied", "prepared"].contains(journal.state) else { throw WritingError.interrupted }
            let stored = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8))
            let edit = stored.prepared, owner = try WritingMCPThumbnailRequest.journalOwner(edit)
            guard edit.documentId == self.document.id, edit.workId == work, owner.exists(in: self.document),
                  let change = edit.changes.first else { throw WritingError.changedScope }
            let before = try Self.thumbnailAttachment(change.before, owner: owner)
            let after = try Self.thumbnailAttachment(change.after, owner: owner)
            try await self.installMCPThumbnail(before, replacing: after, owner: owner, validate: validate)
            try await application.finishWritingEdit(id: id, state: "undone", context: context)
        }
    }

    private func withinMCPThumbnailBoundary(workID: UUID, validate: () throws -> Void,
                                            operation: () async throws -> Void) async throws {
        let session = documentSessionToken, account = snapshotSyncV2AccountScopeToken
        let result: Result<Void, Error> = await documentOperationGate.perform {
            do {
                _ = try await WritingCompositionBoundary.capture {
                    try validate()
                    _ = try self.captureWritingDocument(workUUID: workID)
                    guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                          self.editorCommandSession.prepareForDocumentTransition() else {
                        throw WritingError.changedScope
                    }
                }
                defer { self.editorCommandSession.resumeAfterDocumentTransition() }
                var failure: Error?
                let saved = await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    do {
                        try validate()
                        try await operation()
                        return true
                    } catch {
                        failure = error
                        return false
                    }
                }
                if let failure {
                    throw failure
                }
                guard case let .completed(before, after) = saved, before, after else { throw WritingError.interrupted }
                try validate()
                return .success(())
            } catch { return .failure(error) }
        }
        try result.get()
    }

    private func currentMCPThumbnail(_ owner: ThumbnailOwner) throws -> SyncAttachment? {
        let images = snapshotSyncV2Attachments.filter { $0.fileName == owner.fileName }
        guard images.count <= 1 else { throw WritingError.changedTarget }
        return images.first
    }

    private func installMCPThumbnail(
        _ image: SyncAttachment?,
        replacing expected: SyncAttachment?,
        owner: ThumbnailOwner,
        validate: () throws -> Void
    ) async throws {
        try validate()
        guard owner.exists(in: document),
              try currentMCPThumbnail(owner) == expected else { throw WritingError.changedTarget }
        var candidate = snapshotSyncV2Attachments.filter { $0.fileName != owner.fileName }
        if let image {
            guard !candidate.contains(where: { $0.attachmentId == image.attachmentId }) else {
                throw WritingError.changedTarget
            }
            candidate.append(image)
        }
        guard await checkpointSnapshotSyncV2(document, reason: .explicit, attachments: candidate) else {
            throw WritingError.interrupted
        }
        try validate()
        guard owner.exists(in: document),
              try currentMCPThumbnail(owner) == expected else { throw WritingError.changedTarget }
        removeThumbnailWithOwner(owner)
        if let image {
            snapshotSyncV2Attachments.append(image)
            attachments.append(Attachment(fileName: image.fileName, byteCount: Int64(image.bytes.count)))
        }
    }

    private static func thumbnailValue(_ image: SyncAttachment?) throws -> WritingValue? {
        guard let image else { return nil }
        guard image.bytes.count <= ThumbnailEncoder.maximumBytes else { throw WritingError.invalidEdit }
        return try WritingAttachment(id: image.attachmentId, fileName: image.fileName, bytes: image.bytes).value
    }

    private static func thumbnailAttachment(_ value: WritingValue?, owner: ThumbnailOwner) throws -> SyncAttachment? {
        guard let value else { return nil }
        let image = try JSONDecoder().decode(WritingAttachment.self, from: JSONEncoder().encode(value))
        guard image.fileName == owner.fileName,
              image.bytes.count <= ThumbnailEncoder.maximumBytes else { throw WritingError.invalidEdit }
        return SyncAttachment(attachmentId: image.id, fileName: image.fileName, bytes: image.bytes)
    }
}
#endif
