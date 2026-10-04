import EditorKit
import Foundation
import NovelCore
import NovelTextAnalysis
import NovelWorkspace

extension IOSDocumentStore: WorkspaceReplacementHost {
    var workSearchScope: String {
        "\(String(describing: currentDocumentSessionToken))-\(snapshotSyncV2AccountScope)-\(String(describing: syncV2ActiveWorkID))"
    }

    var episodeHistoryCurrentBody: String? {
        guard let episode = selectedEpisode else { return nil }
        switch captureCommittedText() {
        case let .captured(text): return text
        case .compositionInProgress: return nil
        case .notActive: return episode.content
        }
    }

    func episodeRestoreHost(episodeID: EpisodeID) -> WorkReplacementHost {
        let host = workReplacementHost
        let allowed = { [self] in
            guard selectedEpisodeID == episodeID, document.episode(episodeID) != nil else { return false }
            return host.validate() && snapshotSyncConflict == nil
                && captureCommittedText() != .compositionInProgress
        }
        return WorkReplacementHost(scope: host.scope, validate: allowed, document: host.document,
                                   boundary: host.boundary, snapshot: host.snapshot, apply: host.apply)
    }

    var workReplacementHost: WorkReplacementHost {
        WorkReplacementHostFactory.make(host: self, scope: workSearchScope)
    }

    func checkpointBeforeReplacement() async -> Bool {
        await checkpointSnapshotSyncV2(document, reason: .explicit)
    }

    var replacementInteractionAllowed: Bool {
        !isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress && syncV2KeepBothPendingWorkID == nil
    }

    var selectedEpisodeEditorActive: Bool {
        true
    }

    func replacementBoundary(context: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool {
        let validate = {
            self.operationContext.workID == context.workID && self.operationContext.session == context.session
                && self.operationContext.account == context.account && self.replacementInteractionAllowed && !Task.isCancelled
        }
        return await documentOperationGate.perform {
            guard validate(), self.editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { self.editorCommandSession.resumeAfterDocumentTransition() }
            let result = await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard validate() else { return false }
                return await operation()
            }
            guard validate() else { return false }
            if case let .completed(value, saved) = result {
                return value && saved
            }
            return false
        }
    }

    var currentWorkTextSelectionRequest: EditorSelectionRequest? {
        workTextSelectionToken == currentEpisodeEditingToken ? workTextSelectionRequest : nil
    }

    func selectWorkTextMatch(chapterID: ChapterID, episodeID: EpisodeID, source: String, range: NSRange,
                             expectedScope: String) async -> Bool {
        guard workSearchScope == expectedScope,
              await selectEpisodeAfterDeviceSyncDeparture(chapterID: chapterID, episodeID: episodeID),
              workSearchScope == expectedScope, let current = document.episode(episodeID)?.episode.content,
              WorkTextSearch.sameText(current, source) else { return false }
        workTextSelectionRequest = EditorSelectionRequest(range: range)
        workTextSelectionToken = currentEpisodeEditingToken
        return true
    }
}
