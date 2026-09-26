import EditorKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWritingSupport

extension IOSDocumentStore {
    private var writingInteractionAllowed: Bool {
        startupState == .ready && !isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress && syncV2KeepBothPendingWorkID == nil
    }

    var writingAssistantHost: WritingAssistantHost? {
        guard let application = snapshotSyncV2Application, let work = syncV2ActiveWorkID,
              let workUUID = UUID(uuidString: work.description) else { return nil }
        let session = currentDocumentSessionToken, account = snapshotSyncV2AccountScope
        let validate = { [weak self] in
            guard !Task.isCancelled, let self, currentDocumentSessionToken == session, snapshotSyncV2AccountScope == account,
                  writingInteractionAllowed else { throw WritingError.changedScope }
        }
        let context: () async throws -> SyncV2WritingContext = {
            try validate()
            let result = try await application.writingContext(workID: work)
            try validate(); return result
        }
        return WritingAssistantHost(contextID: "\(String(describing: session))-\(account)", capture: { [weak self] in
            try validate(); guard let self else { throw WritingError.changedScope }
            return try captureWritingDocument(workUUID: workUUID)
        }, records: { common in
            try await application.writingRecords(context: context(), common: common)
        }, append: { record in
            try await application.appendWritingRecord(record, context: context())
        }, synchronize: {
            try await application.synchronizeWriting(context: context())
        }, apply: { [weak self] edit, grant in
            try validate(); guard let self else { throw WritingError.changedScope }
            let ctx = try await context()
            try await applyWritingEdit(edit, grant: grant, application: application, context: ctx, validate: validate)
        }, undo: { [weak self] id in
            try validate(); guard let self else { throw WritingError.changedScope }
            let ctx = try await context()
            guard let journal = try await application.writingEdit(id: id, context: ctx),
                  ["applied", "prepared"].contains(journal.state) else { throw WritingError.interrupted }
            let edit = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8)).prepared
            try await applyWritingEdit(edit.inverse, grant: .wholeWork, application: application, context: ctx, validate: validate)
            try await application.finishWritingEdit(id: id, state: "undone", context: ctx)
        }, editState: { id in
            try await application.writingEdit(id: id, context: context())?.state
        }, editOutcome: { edit in
            try await application.writingEditOutcome(edit, context: context())
        })
    }

    private func captureWritingDocument(workUUID: UUID) throws -> WritingCapture {
        guard writingInteractionAllowed else { throw WritingError.changedScope }
        var captured = document
        switch editorCommandSession.captureActiveCommittedText() {
        case .compositionInProgress: throw AssistantError.composing
        case let .captured(text):
            if let chapter = selectedChapterID, let episode = selectedEpisodeID {
                captured.updateEpisodeContent(text, for: episode, in: chapter)
            }
        case .notActive: break
        }
        guard let attachments = currentV2Attachments() else { throw WritingError.invalidRecord }
        return WritingCapture(
            workId: workUUID,
            document: captured,
            episodeId: selectedEpisodeID,
            attachments: attachments.map { WritingAttachment(id: $0.attachmentId, fileName: $0.fileName, bytes: $0.bytes) }
        )
    }

    private func applyWritingEdit(_ edit: WritingEdit, grant: WritingGrant, application: SyncV2Application,
                                  context: SyncV2WritingContext, validate: () throws -> Void) async throws {
        _ = try await WritingCompositionBoundary.capture {
            try validate(); return try self.captureWritingDocument(workUUID: edit.workId)
        }
        let requested = edit
        let result: Result<Void, Error> = await documentOperationGate.perform {
            do {
                try validate()
                let initial = try await WritingCompositionBoundary.capture {
                    try validate(); return try self.captureWritingDocument(workUUID: edit.workId)
                }
                let edit = try edit.prepared(for: initial.document, attachments: initial.attachments)
                _ = try edit.applying(to: initial.document, attachments: initial.attachments, grant: grant)
                guard try await application.claimWritingEdit(requested, prepared: edit, context: context) else { throw WritingError.alreadyApplied }
                do {
                    try validate()
                    let current = try await WritingCompositionBoundary.capture {
                        try validate(); return try self.captureWritingDocument(workUUID: edit.workId)
                    }
                    let mutation = try edit.applying(to: current.document, attachments: current.attachments, grant: grant)
                    let replacement = mutation.document
                    if let id = self.selectedEpisodeID,
                       let old = current.document.chapters.flatMap(\.episodes).first(where: { $0.id == id }),
                       let new = replacement.chapters.flatMap(\.episodes).first(where: { $0.id == id }), old.content != new.content {
                        if case .captured = self.editorCommandSession.captureActiveCommittedText() {
                            guard self.editorCommandSession.applyProofreading(expectedText: old.content, replacement: new.content) else { throw WritingError.changedTarget }
                        } else {
                            self.editorContentGeneration &+= 1
                        }
                    }
                    self.syncV2AttachmentPayloads = Dictionary(uniqueKeysWithValues: mutation.attachments.map { ($0.fileName, $0.bytes) })
                    self.syncV2AttachmentIDs = Dictionary(uniqueKeysWithValues: mutation.attachments.map { ($0.fileName, $0.id) })
                    self.attachments = mutation.attachments.map { Attachment(fileName: $0.fileName, byteCount: Int64($0.bytes.count)) }
                    self.document = replacement
                    self.repairWritingSelection()
                    self.markDocumentChanged()
                } catch {
                    try? await application.finishWritingEdit(id: edit.id, state: "rejected", context: context)
                    throw error
                }
                // Journal remains prepared on a failed checkpoint; it is never auto-replayed.
                guard await self.saveCoordinator.saveNow() else { throw WritingError.interrupted }
                try await application.finishWritingEdit(id: edit.id, state: "applied", context: context)
                return .success(())
            } catch { return .failure(error) }
        }
        try result.get()
    }

    private func repairWritingSelection() {
        if !document.chapters.contains(where: { $0.id == selectedChapterID }) {
            selectedChapterID = document.chapters.first?.id
        }
        let chapter = document.chapters.first { $0.id == selectedChapterID }
        if chapter?.episodes.contains(where: { $0.id == selectedEpisodeID }) != true {
            selectedEpisodeID = chapter?.episodes.first?.id
        }
    }
}
