import EditorKit
import Foundation
import NovelCore
import NovelSyncV2
import NovelWorkspace

@MainActor
final class FakeWorkspaceHost: WorkspaceAttachmentHost, WorkspaceReplacementHost {
    let editorCommandSession = EditorCommandSession()
    private var outlineSelection: (chapter: ChapterID?, episode: EpisodeID?)?
    var selectedChapterID: ChapterID? {
        get {
            if let outlineSelection {
                return outlineSelection.chapter
            }; return document.chapters.first?.id
        }
        set { outlineSelection = (newValue, selectedEpisodeID) }
    }

    var selectedEpisodeID: EpisodeID? {
        get {
            if let outlineSelection {
                return outlineSelection.episode
            }; return document.chapters.first?.episodes.first?.id
        }
        set { outlineSelection = (selectedChapterID, newValue) }
    }

    var manuscriptCapture: EditorCommittedTextCaptureResult = .notActive
    var clipboard: [String] = []
    var clipboardSucceeds = true
    var departureAllowed = true
    var saveSucceeds = true
    var events: [String] = []
    var savedDepartureSelection: EpisodeID?
    var onDeparture: (@MainActor () async -> Void)?
    var accountGeneration: UInt64 = 0
    var replacementInteractionAllowed = true
    var selectedEpisodeEditorActive = false
    var editorInvalidations = 0
    func captureCommittedText() -> EditorCommittedTextCaptureResult {
        manuscriptCapture
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
                                                                 generation: accountGeneration),
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

extension FakeWorkspaceHost: WorkspaceEpisodeTransitionHost, WorkspaceManuscriptCopyHost {
    func outlineSelectionChanged() {}
    func outlineChapterRemoved(_: ChapterID) {}
    func markOutlineChanged() {
        markChanged(policy: .debounced)
    }

    func episodeTransitionBoundary(context _: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool {
        events.append("commit IME")
        guard departureAllowed else { return false }
        defer { events.append("resume") }
        return await operation()
    }

    var permitsEpisodeTransitionCompletion: Bool {
        permitsLocalMutation
    }

    func prepareEpisodeDeparture() async -> Bool {
        events.append("save departure")
        savedDepartureSelection = selectedEpisodeID
        if let onDeparture {
            await onDeparture()
        }
        return saveSucceeds
    }

    func saveAfterEpisodeTransition() async -> Bool {
        events.append("save selection")
        return saveSucceeds
    }

    var manuscriptEditorActive: Bool {
        selectedEpisodeEditorActive
    }

    func captureManuscriptText(synchronizeModel _: Bool) -> EditorCommittedTextCaptureResult {
        manuscriptCapture
    }

    func writeManuscriptPlainText(_ text: String) -> Bool {
        clipboard.append(text)
        return clipboardSucceeds
    }
}
