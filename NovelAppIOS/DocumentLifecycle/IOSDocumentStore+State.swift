import NovelCore
import NovelWorkspace

extension IOSDocumentStore {
    /// Only the short, document-gate-owned SQLite transition blocks local
    /// document operations. The Apple UI/token exchange may remain suspended
    /// indefinitely; local open/edit/checkpoint/export must continue during
    /// that remote wait.
    var isSyncV2AccountTransitionActive: Bool {
        syncV2AccountTransitionInProgress
    }

    /// Remote work remains fenced for the whole account request window. This
    /// is intentionally separate from `isSyncV2AccountTransitionActive` so a
    /// never-returning Apple exchange cannot freeze the local shelf/editor.
    var isSyncV2RemoteAccountTransitionActive: Bool {
        syncV2AccountTransitionRequested || syncV2AccountTransitionInProgress
    }

    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        startupState = .recovery(message: "本文を安全に保存できる場所を確認できませんでした。")
    }

    func markDocumentChanged(progressAlreadyTracked: Bool = false) {
        guard startupState == .ready,
              workspaceModel.activeWorkID != nil,
              !workspaceModel.isDocumentTransitionInProgress,
              !syncV2AccountTransitionInProgress,
              workspaceModel.keepBothPendingWorkID == nil else { return }
        if !progressAlreadyTracked, let workID = workspaceModel.activeWorkID {
            writingProgress.synchronize(workspaceModel.document, workID: workID.rawValue)
        }
        workspaceModel.editGeneration &+= 1
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    func replaceAttachments(_ value: [Attachment]) {
        workspaceModel.attachments = value
    }

    func advanceDocumentSessionGeneration() {
        workspaceModel.documentSessionToken.generation &+= 1
    }

    func advanceEditorContentGeneration() {
        workspaceModel.editorContentGeneration &+= 1
    }

    var currentPrivateDocumentID: IOSPrivateDocumentID? {
        guard startupState == .ready,
              snapshotSyncV2Application != nil,
              let workID = workspaceModel.activeWorkID else { return nil }
        return IOSPrivateDocumentID(workID: workID)
    }

    var currentDocumentSessionToken: WorkspaceSessionToken? {
        guard currentPrivateDocumentID != nil else { return nil }
        return workspaceModel.activeDocumentSessionToken
    }

    var currentEpisodeEditingToken: IOSEpisodeEditingToken? {
        guard let session = currentDocumentSessionToken,
              let chapterID = workspaceModel.selectedChapterID,
              let episodeID = workspaceModel.selectedEpisodeID else { return nil }
        return IOSEpisodeEditingToken(
            documentSession: session,
            chapterID: chapterID,
            episodeID: episodeID,
            editorContentGeneration: workspaceModel.editorContentGeneration
        )
    }
}
