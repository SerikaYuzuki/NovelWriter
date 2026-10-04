import EditorKit
import NovelWorkspace

extension IOSDocumentStore: WorkspaceManuscriptCopyHost {
    var manuscriptEditorActive: Bool {
        true
    }

    func captureManuscriptText(synchronizeModel: Bool) -> EditorCommittedTextCaptureResult {
        let capture = editorCommandSession.captureActiveCommittedText()
        if synchronizeModel, case let .captured(text) = capture, let selectedChapterID = workspaceModel.selectedChapterID, let selectedEpisodeID = workspaceModel.selectedEpisodeID {
            updateEpisodeContent(text, chapterID: selectedChapterID, episodeID: selectedEpisodeID)
        }
        return capture
    }

    func writeManuscriptPlainText(_ text: String) -> Bool {
        clipboardWriter.writePlainText(text)
    }
}
