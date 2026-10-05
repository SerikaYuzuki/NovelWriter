import EditorKit
import NovelWorkspace

extension AppState: WorkspaceManuscriptCopyHost {
    var manuscriptEditorActive: Bool {
        workspaceSelection.section == .structure
    }

    func captureManuscriptText(synchronizeModel _: Bool) -> EditorCommittedTextCaptureResult {
        activeCommittedTextCapture()
    }

    func writeManuscriptPlainText(_ text: String) -> Bool {
        clipboardWriter.writePlainText(text)
    }
}
