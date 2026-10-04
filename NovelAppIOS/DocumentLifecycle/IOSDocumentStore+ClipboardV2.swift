import Foundation
import NovelCore
import NovelWorkspace

/// 明示した範囲の原稿だけをclipboardへコピーする。
extension IOSDocumentStore {
    func copySelectionManuscript(
        text: String,

        expectedEpisodeID: EpisodeID
    ) {
        guard selectedEpisodeID == expectedEpisodeID else {
            showPromptFailure(.staleContext)
            return
        }
        copyPrompt(source: .selection(text: text))
    }

    func copyEpisodeManuscript(expectedEpisodeID: EpisodeID) {
        guard selectedEpisodeID == expectedEpisodeID else {
            if manuscriptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        guard let episode = synchronizedSelectedEpisodeForCopy() else {
            if manuscriptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        copyPrompt(source: .episode(title: episode.title, content: episode.content))
    }

    func copyChapterManuscript(expectedChapterID: ChapterID) {
        guard selectedChapterID == expectedChapterID else {
            showPromptFailure(.staleContext)
            return
        }
        guard synchronizedSelectedEpisodeForCopy() != nil,
              let chapter = document.chapters.first(where: { $0.id == expectedChapterID }) else {
            if manuscriptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        let episodes = chapter.episodes.map {
            ManuscriptCopyEpisode(title: $0.title, content: $0.content)
        }
        copyPrompt(source: .chapter(title: chapter.title, episodes: episodes))
    }

    private func synchronizedSelectedEpisodeForCopy() -> Episode? {
        guard let selectedChapterID, let selectedEpisodeID else { return nil }
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            updateEpisodeContent(text, chapterID: selectedChapterID, episodeID: selectedEpisodeID)
        case .compositionInProgress:
            showPromptFailure(.compositionInProgress)
            return nil
        case .notActive:
            break
        }
        return document.episode(selectedEpisodeID)?.episode
    }

    private func copyPrompt(source: ManuscriptCopySource) {
        guard startupState == .ready,
              syncV2ActiveWorkID != nil,
              !isDocumentTransitionInProgress,
              !syncV2AccountTransitionInProgress,
              syncV2KeepBothPendingWorkID == nil else {
            showPromptFailure(.staleContext)
            return
        }
        do {
            let prompt = try ManuscriptCopyBuilder.make(source: source)
            guard clipboardWriter.writePlainText(prompt.text) else {
                showPromptFailure(.clipboardWriteFailed)
                return
            }
            manuscriptCopyNotice = .success
        } catch let error as ManuscriptCopyError {
            switch error {
            case .emptyContent: showPromptFailure(.emptyContent)
            case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .outputUTF8ByteLimitExceeded:
                showPromptFailure(.contentTooLarge)
            }
        } catch {
            showPromptFailure(.copyPreparationFailed)
        }
    }

    private func showPromptFailure(_ failure: IOSManuscriptCopyFailure) {
        manuscriptCopyNotice = IOSManuscriptCopyNotice(failure: failure)
    }
}
