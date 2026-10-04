import EditorKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelThumbnail
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingSupport

extension IOSDocumentStore {
    private var writingInteractionAllowed: Bool {
        startupState == .ready && !isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress && syncV2KeepBothPendingWorkID == nil
    }

    func applyAssistantProofreading(_ manuscript: AssistantManuscript, replacement: String,
                                    editingToken: IOSEpisodeEditingToken,
                                    account: WorkspaceAccountScope) -> Bool {
        guard writingInteractionAllowed, currentEpisodeEditingToken == editingToken,
              matchesSyncAccount(account) else { return false }
        return writingProgress.withUncountedEditorChange {
            editorCommandSession.applyProofreading(expectedText: manuscript.content, replacement: replacement)
        }
    }

    var writingAssistantHost: WritingAssistantHost? {
        guard let application = snapshotSyncV2Application, let work = syncV2ActiveWorkID,
              let workUUID = UUID(uuidString: work.description) else { return nil }
        let session = currentDocumentSessionToken, account = snapshotSyncV2AccountScope
        let validate = { [weak self] in
            guard !Task.isCancelled, let self, currentDocumentSessionToken == session, matchesSyncAccount(account),
                  writingInteractionAllowed else { throw WritingError.changedScope }
        }
        // Record delivery belongs to the captured work, independently of the visible document session.
        let context: () async throws -> SyncV2WritingContext = { [weak self] in
            guard let self, matchesSyncAccount(account) else { throw WritingError.changedScope }
            let result = try await application.writingContext(workID: work)
            guard matchesSyncAccount(account) else { throw WritingError.changedScope }
            return result
        }
        let contextID = "\(workUUID)-\(String(describing: session))-\(account)"
        let scheduler = writingSyncScheduler
        var host = WritingAssistantHost(contextID: contextID, workID: workUUID, accountID: String(describing: account), defaults: userDefaults,
                                        requestCenter: assistantRequestCenter, capture: { [weak self] in
                                            try validate(); guard let self else { throw WritingError.changedScope }
                                            return try captureWritingDocument(workUUID: workUUID)
                                        }, records: { common in
                                            try await application.writingRecords(context: context(), common: common)
                                        }, append: { record in
                                            try await application.appendWritingRecord(record, context: context())
                                            scheduler.recordAppended(contextID: contextID)
                                        }, synchronize: {
                                            try await application.synchronizeWriting(context: context())
                                        }, apply: { [weak self] edit, grant in
                                            try validate(); guard let self else { throw WritingError.changedScope }
                                            defer { scheduler.recordAppended(contextID: contextID) }
                                            let ctx = try await context()
                                            try await applyWritingEdit(edit, grant: grant, application: application, context: ctx, validate: validate)
                                        }, undo: { [weak self] id in
                                            try validate(); guard let self else { throw WritingError.changedScope }
                                            defer { scheduler.recordAppended(contextID: contextID) }
                                            let ctx = try await context()
                                            guard let journal = try await application.writingEdit(id: id, context: ctx),
                                                  ["applied", "prepared"].contains(journal.state) else { throw WritingError.interrupted }
                                            let edit = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8)).prepared
                                            try await applyWritingEdit(edit.inverse, grant: .wholeWork, application: application, context: ctx, validate: validate)
                                            try await application.finishWritingEdit(id: id, state: "undone", context: ctx)
                                        }, syncScheduler: scheduler, editState: { id in
                                            try await application.writingEdit(id: id, context: context())?.state
                                        }, editOutcome: { edit in
                                            try await application.writingEditOutcome(edit, context: context())
                                        })
        host.withBackgroundTime = { [weak self] operation in
            guard let self else { throw WritingError.interrupted }
            return try await assistantWithBackgroundTime(operation)
        }
        host.localAccountID = account.accountID ?? "local"
        host.localEdit = { id in
            guard let journal = try await application.writingEdit(id: id, context: context()) else { return nil }
            return try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8)).prepared
        }
        host.applyExactProofreading = { [weak self] edit, grant, episode, text in
            try validate(); guard let self else { throw WritingError.changedScope }
            defer { scheduler.recordAppended(contextID: contextID) }
            try await applyWritingEdit(edit, grant: grant, application: application, context: context(), validate: validate,
                                       exactEpisode: (episode, text))
        }
        return host
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
            attachments: attachments.filter { !ThumbnailOwner.isReserved($0.fileName) }.map { WritingAttachment(id: $0.attachmentId, fileName: $0.fileName, bytes: $0.bytes) }
        )
    }

    private func applyWritingEdit(_ edit: WritingEdit, grant: WritingGrant, application: SyncV2Application,
                                  context: SyncV2WritingContext, validate: () throws -> Void, exactEpisode: (EpisodeID, String)? = nil) async throws {
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
                if let (episode, text) = exactEpisode {
                    guard initial.episodeId == episode, initial.document.chapters.flatMap(\.episodes).first(where: { $0.id == episode })?.content == text else { throw WritingError.changedTarget }
                }
                let edit = try edit.prepared(for: initial.document, attachments: initial.attachments)
                _ = try edit.applying(to: initial.document, attachments: initial.attachments, grant: grant)
                guard try await application.claimWritingEdit(requested, prepared: edit, context: context) else { throw WritingError.alreadyApplied }
                do {
                    try validate()
                    let current = try await WritingCompositionBoundary.capture {
                        try validate(); return try self.captureWritingDocument(workUUID: edit.workId)
                    }
                    if let (episode, text) = exactEpisode {
                        guard current.episodeId == episode, current.document.chapters.flatMap(\.episodes).first(where: { $0.id == episode })?.content == text else { throw WritingError.changedTarget }
                    }
                    let mutation = try edit.applying(to: current.document, attachments: current.attachments, grant: grant)
                    let replacement = mutation.document
                    let mergedAttachments = try WritingThumbnailBoundary.merging(mutation.attachments,
                                                                                 with: (self.currentV2Attachments() ?? []).map {
                                                                                     WritingAttachment(id: $0.attachmentId, fileName: $0.fileName, bytes: $0.bytes)
                                                                                 },
                                                                                 from: current.document, to: replacement)
                    if let id = self.selectedEpisodeID,
                       let old = current.document.chapters.flatMap(\.episodes).first(where: { $0.id == id }),
                       let new = replacement.chapters.flatMap(\.episodes).first(where: { $0.id == id }), old.content != new.content {
                        if case .captured = self.editorCommandSession.captureActiveCommittedText() {
                            let applied = self.writingProgress.withUncountedEditorChange {
                                self.editorCommandSession.applyProofreading(expectedText: old.content, replacement: new.content)
                            }
                            guard applied else { throw WritingError.changedTarget }
                        } else {
                            self.editorContentGeneration &+= 1
                        }
                    }
                    self.syncV2AttachmentPayloads = Dictionary(uniqueKeysWithValues: mergedAttachments.map { ($0.fileName, $0.bytes) })
                    self.syncV2AttachmentIDs = Dictionary(uniqueKeysWithValues: mergedAttachments.map { ($0.fileName, $0.id) })
                    self.attachments = mergedAttachments.map { Attachment(fileName: $0.fileName, byteCount: Int64($0.bytes.count)) }
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
