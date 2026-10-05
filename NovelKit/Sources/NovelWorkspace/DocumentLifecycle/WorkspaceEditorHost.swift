import EditorKit
import NovelCore

/// Editor capability of the workspace port; never exposes a native text view.
@MainActor
public protocol WorkspaceEditorHost: WorkspaceHost {
    var editorCommandSession: EditorCommandSession { get }
    var selectedChapterID: ChapterID? { get }
    var selectedEpisodeID: EpisodeID? { get }
    func captureCommittedText() -> EditorCommittedTextCaptureResult
    func applyUncountedProofreading(expectedText: String, replacement: String) -> Bool
    func invalidateEditorContent()
    func markWritingDocumentChanged()
}
