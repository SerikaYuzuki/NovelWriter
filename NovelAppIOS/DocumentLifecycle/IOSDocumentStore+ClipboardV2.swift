import NovelCore
import NovelWorkspace

extension IOSDocumentStore {
    func copySelectionManuscript(text: String, expectedEpisodeID: EpisodeID) {
        guard selectedEpisodeID == expectedEpisodeID, let selectedChapterID else {
            manuscriptCopyNotice = IOSManuscriptCopyNotice(failure: .staleContext)
            return
        }
        copyManuscript(.selection(text: text, chapterID: selectedChapterID, episodeID: expectedEpisodeID))
    }

    func copyEpisodeManuscript(expectedEpisodeID: EpisodeID) {
        guard selectedEpisodeID == expectedEpisodeID, let selectedChapterID else {
            if manuscriptCopyNotice == nil {
                manuscriptCopyNotice = IOSManuscriptCopyNotice(failure: .staleContext)
            }
            return
        }
        copyManuscript(.episode(chapterID: selectedChapterID, episodeID: expectedEpisodeID))
    }

    func copyChapterManuscript(expectedChapterID: ChapterID) {
        guard selectedChapterID == expectedChapterID else {
            manuscriptCopyNotice = IOSManuscriptCopyNotice(failure: .staleContext)
            return
        }
        guard selectedEpisodeID != nil else {
            if manuscriptCopyNotice == nil {
                manuscriptCopyNotice = IOSManuscriptCopyNotice(failure: .staleContext)
            }
            return
        }
        copyManuscript(.chapter(expectedChapterID))
    }

    private func copyManuscript(_ request: ManuscriptCopyRequest) {
        let outcome = ManuscriptCopyCommand(host: self).copy(request, expectedSession: currentDocumentSessionToken,
                                                             requireActiveSelection: false, synchronizeModel: true)
        if case let .failure(failure) = outcome {
            manuscriptCopyNotice = IOSManuscriptCopyNotice(failure: failure)
        } else {
            manuscriptCopyNotice = .success
        }
    }
}
