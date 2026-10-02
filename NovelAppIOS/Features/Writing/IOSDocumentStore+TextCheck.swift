import Foundation
import NovelTextAnalysis

extension IOSDocumentStore {
    func synchronizeTextCheck() {
        textCheck.synchronize(document: document, workID: syncV2ActiveWorkID?.rawValue, scope: workSearchScope)
    }

    func runTextCheck() async {
        let scope = workSearchScope
        guard await prepareForEditorSurfaceDeparture(), workSearchScope == scope, let work = syncV2ActiveWorkID else { return }
        let snapshot = document, episode = textCheck.allWork ? nil : selectedEpisodeID
        guard textCheck.allWork || episode != nil else { return }
        await textCheck.check(document: snapshot, workID: work.rawValue, scope: scope, episodeID: episode) {
            self.workSearchScope == scope && !self.isDocumentTransitionInProgress && !self.syncV2AccountTransitionInProgress
                && self.document.chapters == snapshot.chapters && self.document.characters == snapshot.characters
                && (self.textCheck.allWork || self.selectedEpisodeID == episode)
        }
    }

    func prepareTextCheckReplacement(_ issue: TextCheckIssue) -> Bool {
        synchronizeTextCheck()
        return textCheck.prefillReplacement(issue, search: workSearch, expectedScope: workSearchScope)
    }
}
