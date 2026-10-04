#if os(macOS)
import EditorKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingSupport

extension AppState: WorkspaceWritingHost {
    var writingInteractionAllowed: Bool {
        permitsDocumentInteraction && workspaceModel.activeWorkID != nil
    }

    var writingApplication: SyncV2Application? {
        snapshotSyncV2Application
    }

    func captureCommittedText() -> EditorCommittedTextCaptureResult {
        activeCommittedTextCapture()
    }

    func writingAttachments() throws -> [WritingAttachment] {
        snapshotSyncV2Attachments.map { WritingAttachment(id: $0.attachmentId, fileName: $0.fileName, bytes: $0.bytes) }
    }

    func installWritingMutation(_ replacement: NovelDocument, attachments values: [WritingAttachment]) throws {
        snapshotSyncV2Attachments = values.map { SyncAttachment(attachmentId: $0.id, fileName: $0.fileName, bytes: $0.bytes) }
        workspaceModel.attachments = values.map { Attachment(fileName: $0.fileName, byteCount: Int64($0.bytes.count)) }
        attachmentPreviewURLs.removeAll()
        workspaceModel.document = replacement
        repairWritingSelection()
    }

    func saveWritingChanges() async -> Bool {
        await saveNow()
    }

    func markWritingDocumentChanged() {
        markDocumentDirty()
    }

    func captureWritingDocument(workUUID: UUID) throws -> WritingCapture {
        try WritingAssistantHostFactory.capture(host: self, workUUID: workUUID)
    }

    var writingAssistantHost: WritingAssistantHost? {
        guard let application = snapshotSyncV2Application, let work = workspaceModel.activeWorkID,
              let workUUID = UUID(uuidString: work.description) else { return nil }
        let scope = operationContext
        let contextID = "\(workUUID)-\(workspaceModel.documentSessionToken)-\(snapshotSyncV2AccountScopeToken)"
        let validate = { [weak self] in
            guard !Task.isCancelled, let self, writingInteractionAllowed,
                  operationContext.workID == scope.workID, operationContext.session == scope.session,
                  operationContext.account == scope.account else { throw WritingError.changedScope }
        }
        let context: () async throws -> SyncV2WritingContext = { [weak self] in
            guard let self, operationContext.account == scope.account else { throw WritingError.changedScope }
            let result = try await application.writingContext(workID: work)
            guard operationContext.account == scope.account else { throw WritingError.changedScope }
            return result
        }
        guard var host = WritingAssistantHostFactory.make(host: self, contextID: contextID, thumbnailUndo: { [weak self] id, application, context, validate in
            guard let self else { throw WritingError.changedScope }
            try await undoMCPThumbnail(id, application: application, context: context, validate: validate)
        }) else { return nil }
        host.transmit = AssistantTransport.sendSaved
        host.readThumbnail = { [weak self] owner in
            guard let self else { throw WritingError.changedScope }
            return try readMCPThumbnail(owner, validate: validate)
        }
        host.applyThumbnail = { [weak self] request, grant in
            try validate(); guard let self else { throw WritingError.changedScope }
            defer { writingSyncScheduler.recordAppended(contextID: contextID) }
            return try await applyMCPThumbnail(request, grant: grant, application: application, context: context(), validate: validate)
        }
        return host
    }

    func applyUncountedProofreading(expectedText: String, replacement: String) -> Bool {
        writingProgress.withUncountedEditorChange {
            editorCommandSession.applyProofreading(expectedText: expectedText, replacement: replacement)
        }
    }

    func invalidateEditorContent() {
        workspaceModel.editorContentGeneration &+= 1
    }

    private func repairWritingSelection() {
        if !workspaceModel.document.chapters.contains(where: { $0.id == workspaceModel.selectedChapterID }) {
            workspaceModel.selectedChapterID = workspaceModel.document.chapters.first?.id
        }
        let chapter = workspaceModel.document.chapters.first { $0.id == workspaceModel.selectedChapterID }
        if chapter?.episodes.contains(where: { $0.id == workspaceModel.selectedEpisodeID }) != true {
            workspaceModel.selectedEpisodeID = chapter?.episodes.first?.id
        }
        if !workspaceModel.document.characters.contains(where: { $0.id == selectedCharacterID }) {
            selectedCharacterID = nil
        }
        if !workspaceModel.document.plotCards.contains(where: { $0.id == selectedPlotCardID }) {
            selectedPlotCardID = nil
        }
        if !workspaceModel.document.flags.contains(where: { $0.id == selectedFlagID }) {
            selectedFlagID = nil
        }
        if !workspaceModel.document.worldNotes.contains(where: { $0.id == selectedWorldNoteID }) {
            selectedWorldNoteID = nil
        }
    }
}
#endif
