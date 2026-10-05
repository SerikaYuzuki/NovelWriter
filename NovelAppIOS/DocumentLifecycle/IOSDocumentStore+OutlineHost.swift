import NovelCore
import NovelWorkspace

extension IOSDocumentStore: WorkspaceEpisodeTransitionHost {
    /// Selection requirements shared by outline transitions and manuscript copying.
    var selectedChapterID: ChapterID? {
        get { workspaceModel.selectedChapterID }
        set { workspaceModel.selectedChapterID = newValue }
    }

    var selectedEpisodeID: EpisodeID? {
        get { workspaceModel.selectedEpisodeID }
        set { workspaceModel.selectedEpisodeID = newValue }
    }

    func outlineSelectionChanged() {}
    func outlineChapterRemoved(_: ChapterID) {}
    func markOutlineChanged() {
        markDocumentChanged()
    }

    func episodeTransitionBoundary(context: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool {
        await documentOperationGate.perform {
            let current = self.operationContext
            guard self.permitsLocalMutation, current.session == context.session,
                  current.workID == context.workID, current.account == context.account else { return false }
            return await operation()
        }
    }

    var permitsEpisodeTransitionCompletion: Bool {
        permitsLocalMutation
    }

    /// Keep the iOS navigation-departure hook and its editor resume policy.
    func prepareEpisodeDeparture() async -> Bool {
        await prepareForEditorSurfaceDeparture()
    }

    func saveAfterEpisodeTransition() async -> Bool {
        await saveNow()
    }
}
