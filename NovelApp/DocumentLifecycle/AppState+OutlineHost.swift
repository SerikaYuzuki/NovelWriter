import NovelCore
import NovelWorkspace

extension AppState: WorkspaceEpisodeTransitionHost {
    func outlineCommands(_ policy: WorkspaceSavePolicy? = nil, prepared: Bool = false) -> OutlineCommands {
        OutlineCommands(host: self, policy: policy, preparedTransition: prepared)
    }

    func outlineSelectionChanged() {
        plotOutlineSelection = selectedChapterID.map { .chapter($0) } ?? .unassigned
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
            self.isDocumentTransitionInProgress = true
            defer { self.isDocumentTransitionInProgress = false }
            return await operation()
        }
    }

    var permitsEpisodeTransitionCompletion: Bool {
        startupState.isReady && isDocumentTransitionInProgress && !isTerminationPending && syncV2KeepBothPendingWorkID == nil
    }

    func prepareEpisodeDeparture() async -> Bool {
        await saveNow()
    }

    func saveAfterEpisodeTransition() async -> Bool {
        await saveNow()
    }
}
