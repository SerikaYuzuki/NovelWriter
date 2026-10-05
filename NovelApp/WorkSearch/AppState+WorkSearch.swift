import EditorKit
import Foundation
import NovelCore
import NovelTextAnalysis
import NovelWorkspace

extension AppState: WorkspaceReplacementHost {
    var workSearchScope: String {
        "\(workspaceModel.documentSessionToken)-\(snapshotSyncV2AccountScopeToken)-\(String(describing: workspaceModel.activeWorkID))"
    }

    func presentWorkSearch(query: String? = nil, replacement: String? = nil) async {
        let session = workspaceModel.documentSessionToken, account = snapshotSyncV2AccountScopeToken
        guard await selectProjectSectionAfterTransition(.structure), workspaceModel.documentSessionToken == session,
              snapshotSyncV2AccountScopeToken == account else { return }
        if let query {
            workSearch.query = query
        }
        if let replacement {
            workSearch.replacement = replacement
        }
        workSearch.isPresented = true
    }

    /// 作品全体検索の、保存・scope・本文一致を通すジャンプ。
    func selectWorkTextMatch(_ result: EpisodeTextMatches, match: WorkTextMatch,
                             expectedScope: String, editorSearch: EditorSearchSession) async -> Bool {
        guard workSearchScope == expectedScope,
              await selectEpisodeAfterTransition(result.id, in: result.chapterID),
              workSearchScope == expectedScope,
              let current = workspaceModel.document.episode(result.id)?.episode.content,
              WorkTextSearch.sameText(current, result.source) else { return false }
        editorSearch.requestSelection(range: match.range, episodeID: result.id)
        return true
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
            guard workspaceModel.selectedEpisodeID == episodeID, workspaceModel.document.episode(episodeID) != nil else { return false }
            return host.validate() && workspaceModel.syncConflict == nil
                && captureCommittedText() != .compositionInProgress
        }
        return WorkReplacementHost(scope: host.scope, validate: allowed, document: host.document,
                                   boundary: host.boundary, snapshot: host.snapshot, apply: host.apply)
    }

    var workReplacementHost: WorkReplacementHost {
        WorkReplacementHostFactory.make(host: self, scope: workSearchScope)
    }

    func checkpointBeforeReplacement() async -> Bool {
        await checkpointSnapshotSyncV2(workspaceModel.document, reason: .explicit)
    }

    var replacementInteractionAllowed: Bool {
        permitsDocumentInteraction && workspaceModel.activeWorkID != nil
    }

    var selectedEpisodeEditorActive: Bool {
        workspaceSelection.section == .structure
    }

    func replacementBoundary(context: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool {
        guard let session = context.session else { return false }
        return await performSnapshotDataMutation(expectedSession: session) { await operation() }
    }
}
