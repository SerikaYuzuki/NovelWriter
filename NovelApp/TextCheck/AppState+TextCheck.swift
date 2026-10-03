import Foundation
import NovelTextAnalysis

extension AppState {
    func presentTextCheck() async {
        let scope = workSearchScope
        guard await selectProjectSectionAfterTransition(.structure), workSearchScope == scope else { return }
        synchronizeTextCheck()
        workSearch.isPresented = false
        textCheck.isPresented = true
    }

    func synchronizeTextCheck() {
        textCheck.synchronize(document: document, workID: snapshotSyncV2ActiveWorkID?.rawValue, scope: workSearchScope)
    }

    func runTextCheck() async {
        let scope = workSearchScope
        guard permitsDocumentInteraction, await selectProjectSectionAfterTransition(.structure),
              workSearchScope == scope, let work = snapshotSyncV2ActiveWorkID else { return }
        let snapshot = document, episode = textCheck.allWork ? nil : selectedEpisodeID
        guard textCheck.allWork || episode != nil else { return }
        await textCheck.check(document: snapshot, workID: work.rawValue, scope: scope, episodeID: episode) {
            self.workSearchScope == scope && self.permitsDocumentInteraction && self.document.chapters == snapshot.chapters
                && self.document.characters == snapshot.characters && (self.textCheck.allWork || self.selectedEpisodeID == episode)
        }
    }

    func presentTextCheckReplacement(_ issue: TextCheckIssue) async -> Bool {
        let scope = workSearchScope
        synchronizeTextCheck()
        guard textCheck.prefillReplacement(issue, search: workSearch, expectedScope: scope) else { return false }
        await presentWorkSearch(query: workSearch.query, replacement: workSearch.replacement)
        return workSearchScope == scope && workSearch.isPresented
    }
}
