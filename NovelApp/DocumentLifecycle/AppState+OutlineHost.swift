import NovelCore
import NovelWorkspace

extension AppState: WorkspaceEpisodeTransitionHost {
    /// Selection requirements shared by outline transitions and manuscript copying.
    var selectedChapterID: ChapterID? {
        get { workspaceModel.selectedChapterID }
        set { workspaceModel.selectedChapterID = newValue }
    }

    var selectedEpisodeID: EpisodeID? {
        get { workspaceModel.selectedEpisodeID }
        set { workspaceModel.selectedEpisodeID = newValue }
    }

    func outlineCommands(_ policy: WorkspaceSavePolicy? = nil, prepared: Bool = false) -> OutlineCommands {
        OutlineCommands(host: self, policy: policy, preparedTransition: prepared)
    }

    func outlineSelectionChanged() {
        plotOutlineSelection = workspaceModel.selectedChapterID.map { .chapter($0) } ?? .unassigned
    }

    func outlineChapterRemoved(_ id: ChapterID) {
        if case let .chapter(focused) = plotOutlineSelection, focused == id {
            outlineSelectionChanged()
        }
    }

    func markOutlineChanged() {
        saveCoordinator.markDirty()
    }

    func episodeTransitionBoundary(context: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool {
        await documentOperationGate.perform {
            let current = self.operationContext
            guard self.permitsDocumentInteraction, current.session == context.session,
                  current.workID == context.workID, current.account == context.account,
                  self.editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { self.editorCommandSession.resumeAfterDocumentTransition() }
            self.workspaceModel.isDocumentTransitionInProgress = true
            defer { self.workspaceModel.isDocumentTransitionInProgress = false }
            return await operation()
        }
    }

    var permitsEpisodeTransitionCompletion: Bool {
        startupState.isReady && workspaceModel.isDocumentTransitionInProgress && !isTerminationPending && workspaceModel.keepBothPendingWorkID == nil
    }

    func prepareEpisodeDeparture() async -> Bool {
        await saveNow()
    }

    func saveAfterEpisodeTransition() async -> Bool {
        await saveNow()
    }
}
