import EditorKit
import Foundation
import NovelCore
import NovelTextAnalysis
import NovelWorkspace

extension IOSDocumentStore {
    var workSearchScope: String {
        "\(String(describing: currentDocumentSessionToken))-\(snapshotSyncV2AccountScope)-\(String(describing: syncV2ActiveWorkID))"
    }

    var episodeHistoryCurrentBody: String? {
        guard let episode = selectedEpisode else { return nil }
        switch editorCommandSession.captureActiveCommittedText() {
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
                && editorCommandSession.captureActiveCommittedText() != .compositionInProgress
        }
        return WorkReplacementHost(scope: host.scope, validate: allowed, document: host.document,
                                   boundary: host.boundary, snapshot: host.snapshot, apply: host.apply)
    }

    var episodeHistoryCurrentBody: String? {
        guard let episode = selectedEpisode else { return nil }
        switch editorCommandSession.captureActiveCommittedText() {
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
                && editorCommandSession.captureActiveCommittedText() != .compositionInProgress
        }
        return WorkReplacementHost(scope: host.scope, validate: allowed, document: host.document,
                                   boundary: host.boundary, snapshot: host.snapshot, apply: host.apply)
    }

    var workReplacementHost: WorkReplacementHost {
        let session = currentDocumentSessionToken, account = snapshotSyncV2AccountScope, work = syncV2ActiveWorkID
        let validate = { [self] in currentDocumentSessionToken == session && snapshotSyncV2AccountScope == account
            && syncV2ActiveWorkID == work && work != nil && !isDocumentTransitionInProgress
            && !syncV2AccountTransitionInProgress && syncV2KeepBothPendingWorkID == nil && !Task.isCancelled
        }
        return WorkReplacementHost(
            scope: workSearchScope,
            validate: validate,
            document: { self.document },
            boundary: { operation in
                await self.documentOperationGate.perform {
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
            },
            snapshot: {
                guard validate() else { return false }
                return await self.checkpointSnapshotSyncV2(self.document, reason: .explicit)
            },
            apply: { changes in
                guard validate(), changes.allSatisfy({ $0.matches(self.document) }) else { return false }
                if let active = changes.first(where: { $0.episodeID == self.selectedEpisodeID }) {
                    if case .captured = self.editorCommandSession.captureActiveCommittedText() {
                        self.editorCommandSession.resumeAfterDocumentTransition()
                        let applied = self.writingProgress.withUncountedEditorChange {
                            self.editorCommandSession.applyProofreading(
                                expectedText: active.before,
                                replacement: active.after
                            )
                        }
                        let prepared = self.editorCommandSession.prepareForDocumentTransition()
                        guard applied, prepared else { return false }
                    } else {
                        self.editorContentGeneration &+= 1
                    }
                }
                for change in changes {
                    self.document.updateEpisodeContent(change.after, for: change.episodeID, in: change.chapterID)
                }
                self.markDocumentChanged()
                return true
            }
        )
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
