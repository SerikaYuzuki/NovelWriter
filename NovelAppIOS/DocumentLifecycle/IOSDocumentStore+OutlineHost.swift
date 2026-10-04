import NovelCore
import NovelWorkspace

extension IOSDocumentStore: WorkspaceEpisodeTransitionHost {
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
