import NovelCore

extension IOSDocumentStore {
    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        startupState = .recovery(message: "本文を安全に保存できる場所を確認できませんでした。")
    }

    func markDocumentChanged() {
        guard startupState == .ready,
              syncV2ActiveWorkID != nil,
              !isDocumentTransitionInProgress,
              !syncV2AccountTransitionInProgress,
              syncV2KeepBothPendingWorkID == nil else { return }
        localEditGeneration &+= 1
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    func replaceAttachments(_ value: [Attachment]) {
        attachments = value
    }

    func advanceDocumentSessionGeneration() {
        documentSessionGeneration &+= 1
    }

    func advanceEditorContentGeneration() {
        editorContentGeneration &+= 1
    }

    var currentPrivateDocumentID: IOSPrivateDocumentID? {
        guard startupState == .ready,
              snapshotSyncV2Application != nil,
              let workID = syncV2ActiveWorkID else { return nil }
        return IOSPrivateDocumentID(workID: workID)
    }

    var currentDocumentSessionToken: IOSDocumentSessionToken? {
        guard let id = currentPrivateDocumentID else { return nil }
        return IOSDocumentSessionToken(workingCopyID: id, generation: documentSessionGeneration)
    }

    var currentEpisodeEditingToken: IOSEpisodeEditingToken? {
        guard let session = currentDocumentSessionToken,
              let chapterID = selectedChapterID,
              let episodeID = selectedEpisodeID else { return nil }
        return IOSEpisodeEditingToken(
            documentSession: session,
            chapterID: chapterID,
            episodeID: episodeID,
            editorContentGeneration: editorContentGeneration
        )
    }
}
