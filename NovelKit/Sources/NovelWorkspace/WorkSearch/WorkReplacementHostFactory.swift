import NovelCore
import NovelTextAnalysis

@MainActor
public protocol WorkspaceReplacementHost: WorkspaceEditorHost {
    var replacementInteractionAllowed: Bool { get }
    var selectedEpisodeEditorActive: Bool { get }
    func replacementBoundary(context: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool
    func checkpointBeforeReplacement() async -> Bool
}

@MainActor
public enum WorkReplacementHostFactory {
    public static func make(host: any WorkspaceReplacementHost, scope: String) -> WorkReplacementHost {
        let context = host.operationContext
        let validate = {
            let current = host.operationContext
            return context.workID != nil && context.workID == current.workID
                && context.session == current.session && context.account == current.account
                && host.replacementInteractionAllowed && !Task.isCancelled
        }
        return WorkReplacementHost(scope: scope, validate: validate, document: { host.document }, boundary: { operation in
            guard validate() else { return false }
            return await host.replacementBoundary(context: context) {
                guard validate() else { return false }
                return await operation()
            }
        }, snapshot: {
            guard validate() else { return false }
            return await host.checkpointBeforeReplacement()
        }, apply: { changes in
            guard validate(), changes.allSatisfy({ $0.matches(host.document) }) else { return false }
            if host.selectedEpisodeEditorActive,
               let active = changes.first(where: { $0.episodeID == host.selectedEpisodeID }) {
                if case .captured = host.captureCommittedText() {
                    host.editorCommandSession.resumeAfterDocumentTransition()
                    let applied = host.applyUncountedProofreading(expectedText: active.before, replacement: active.after)
                    let prepared = host.editorCommandSession.prepareForDocumentTransition()
                    guard applied, prepared else { return false }
                } else {
                    host.invalidateEditorContent()
                }
            }
            for change in changes {
                host.document.updateEpisodeContent(change.after, for: change.episodeID, in: change.chapterID)
            }
            host.markWritingDocumentChanged()
            return true
        })
    }
}
