import EditorKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelWorkspace

@MainActor
final class FakeWorkspaceHost: WorkspaceAttachmentHost, WorkspaceReplacementHost {
    let editorCommandSession = EditorCommandSession()
    var selectedChapterID: ChapterID? {
        document.chapters.first?.id
    }

    var selectedEpisodeID: EpisodeID? {
        document.chapters.first?.episodes.first?.id
    }

    var replacementInteractionAllowed = true
    var selectedEpisodeEditorActive = false
    var editorInvalidations = 0
    func captureCommittedText() -> EditorCommittedTextCaptureResult {
        .notActive
    }

    func applyUncountedProofreading(expectedText _: String, replacement _: String) -> Bool {
        false
    }

    func invalidateEditorContent() {
        editorInvalidations += 1
    }

    func markWritingDocumentChanged() {
        markChanged(policy: .debounced)
    }

    func replacementBoundary(context _: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool {
        await operation()
    }

    func checkpointBeforeReplacement() async -> Bool {
        true
    }

    var workspaceAttachments = WorkspaceAttachmentSet()
    var document = NovelDocument.newDocument()
    var session: WorkspaceSessionToken
    var permitsLocalMutation = true
    var policies: [WorkspaceSavePolicy] = []
    var ownerRemovals: [NovelDocument] = []
    var markedDocuments: [NovelDocument] = []

    init() {
        session = WorkspaceSessionToken(generation: 1, documentID: document.id, workID: WorkID(UUID()))
    }

    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(workID: session.workID, session: session,
                                  account: WorkspaceAccountScope(accountID: nil, accountFence: nil,
                                                                 serverInstanceID: nil, protocolEpoch: nil,
                                                                 generation: 0),
                                  editGeneration: nil)
    }

    func installWorkspaceAttachments(_ replacement: WorkspaceAttachmentSet) {
        workspaceAttachments = replacement
    }

    func markChanged(policy: WorkspaceSavePolicy) {
        policies.append(policy)
        markedDocuments.append(document)
    }

    func applyOwnerRemoval(_ replacement: NovelDocument) {
        ownerRemovals.append(replacement)
        WorkspaceAttachmentCommands.applyOwnerRemoval(replacement, host: self)
    }
}
