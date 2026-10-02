import EditorKit
import Foundation
import NovelCore
import NovelTextAnalysis

extension AppState {
    var workSearchScope: String {
        "\(documentSessionToken)-\(snapshotSyncV2AccountScopeToken)-\(String(describing: snapshotSyncV2ActiveWorkID))"
    }

    func presentWorkSearch(query: String? = nil) async {
        let session = documentSessionToken, account = snapshotSyncV2AccountScopeToken
        guard await selectProjectSectionAfterTransition(.structure), documentSessionToken == session,
              snapshotSyncV2AccountScopeToken == account else { return }
        if let query {
            workSearch.query = query
        }
        workSearch.isPresented = true
    }

    var workReplacementHost: WorkReplacementHost {
        let session = documentSessionToken, account = snapshotSyncV2AccountScopeToken, work = snapshotSyncV2ActiveWorkID
        let validate = { [self] in documentSessionToken == session && snapshotSyncV2AccountScopeToken == account
            && snapshotSyncV2ActiveWorkID == work && work != nil && permitsDocumentInteraction && !Task.isCancelled
        }
        return WorkReplacementHost(
            scope: workSearchScope,
            validate: validate,
            document: { self.document },
            boundary: { operation in
                guard validate() else { return false }
                return await self.performSnapshotDataMutation(expectedSession: session) {
                    guard validate() else { return false }
                    return await operation()
                }
            },
            snapshot: {
                guard validate() else { return false }
                return await self.checkpointSnapshotSyncV2(self.document, reason: .explicit)
            },
            apply: { changes in
                guard validate(), changes.allSatisfy({ $0.matches(self.document) }) else { return false }
                if self.workspaceSelection.section == .structure,
                   let active = changes.first(where: { $0.episodeID == self.selectedEpisodeID }) {
                    if case .captured = self.activeCommittedTextCapture() {
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
                self.markDocumentDirty()
                return true
            }
        )
    }
}
