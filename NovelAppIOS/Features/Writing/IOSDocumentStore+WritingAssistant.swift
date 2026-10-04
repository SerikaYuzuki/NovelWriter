import EditorKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingSupport

extension IOSDocumentStore: WorkspaceWritingHost {
    var writingInteractionAllowed: Bool {
        startupState == .ready && !workspaceModel.isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress && workspaceModel.keepBothPendingWorkID == nil
    }

    func applyAssistantProofreading(_ manuscript: AssistantManuscript, replacement: String,
                                    editingToken: IOSEpisodeEditingToken, account: WorkspaceAccountScope) -> Bool {
        guard writingInteractionAllowed, currentEpisodeEditingToken == editingToken,
              matchesSyncAccount(account) else { return false }
        return applyUncountedProofreading(expectedText: manuscript.content, replacement: replacement)
    }

    var writingApplication: SyncV2Application? {
        snapshotSyncV2Application
    }

    func captureCommittedText() -> EditorCommittedTextCaptureResult {
        editorCommandSession.captureActiveCommittedText()
    }

    func writingAttachments() throws -> [WritingAttachment] {
        guard let attachments = currentV2Attachments() else { throw WritingError.invalidRecord }
        return attachments.map { WritingAttachment(id: $0.attachmentId, fileName: $0.fileName, bytes: $0.bytes) }
    }

    func installWritingMutation(_ replacement: NovelDocument, attachments: [WritingAttachment]) throws {
        guard adoptV2AttachmentRecords(attachments.map { SyncAttachment(attachmentId: $0.id, fileName: $0.fileName, bytes: $0.bytes) }) else {
            throw WritingError.changedTarget
        }
        workspaceModel.document = replacement
        workspaceModel.documentSessionToken.documentID = replacement.id
        repairWritingSelection()
    }

    func saveWritingChanges() async -> Bool {
        await saveCoordinator.saveNow()
    }

    func markWritingDocumentChanged() {
        markDocumentChanged()
    }

    var writingAssistantHost: WritingAssistantHost? {
        guard let work = workspaceModel.activeWorkID, let workUUID = UUID(uuidString: work.description) else { return nil }
        let contextID = "\(workUUID)-\(String(describing: currentDocumentSessionToken))-\(snapshotSyncV2AccountScope)"
        guard var host = WritingAssistantHostFactory.make(host: self, contextID: contextID) else { return nil }
        host.transmit = AssistantTransport.sendSaved
        host.withBackgroundTime = { [weak self] operation in
            guard let self else { throw WritingError.interrupted }
            return try await assistantWithBackgroundTime(operation)
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
    }
}
