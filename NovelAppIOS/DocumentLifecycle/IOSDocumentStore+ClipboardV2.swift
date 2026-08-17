import Foundation
import NovelCore

/// 通常版のAI支援は、明示した本文をローカルでprompt化してclipboardへコピーするだけに留める。
extension IOSDocumentStore {
    func copySelectionPrompt(
        text: String,
        purpose: AIClipboardPromptPurpose,
        expectedEpisodeID: EpisodeID
    ) {
        guard selectedEpisodeID == expectedEpisodeID else {
            showPromptFailure(.staleContext)
            return
        }
        copyPrompt(purpose: purpose, source: .selection(text: text))
    }

    func copyEpisodePrompt(purpose: AIClipboardPromptPurpose, expectedEpisodeID: EpisodeID) {
        guard selectedEpisodeID == expectedEpisodeID else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        guard let episode = synchronizedSelectedEpisodeForPrompt() else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        copyPrompt(purpose: purpose, source: .episode(title: episode.title, content: episode.content))
    }

    func copyChapterPrompt(purpose: AIClipboardPromptPurpose, expectedChapterID: ChapterID) {
        guard selectedChapterID == expectedChapterID else {
            showPromptFailure(.staleContext)
            return
        }
        guard synchronizedSelectedEpisodeForPrompt() != nil,
              let chapter = document.chapters.first(where: { $0.id == expectedChapterID }) else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        let episodes = chapter.episodes.map {
            AIClipboardPromptEpisode(title: $0.title, content: $0.content)
        }
        copyPrompt(purpose: purpose, source: .chapter(title: chapter.title, episodes: episodes))
    }

    private func synchronizedSelectedEpisodeForPrompt() -> Episode? {
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

    private func copyPrompt(purpose: AIClipboardPromptPurpose, source: AIClipboardPromptSource) {
        do {
            let prompt = try AIClipboardPromptBuilder.make(purpose: purpose, source: source)
            guard clipboardWriter.writePlainText(prompt.text) else {
                showPromptFailure(.clipboardWriteFailed)
                return
            }
            promptCopyNotice = .success
        } catch let error as AIClipboardPromptError {
            switch error {
            case .emptyContent: showPromptFailure(.emptyContent)
            case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .promptUTF8ByteLimitExceeded:
                showPromptFailure(.contentTooLarge)
            case .encodingFailed: showPromptFailure(.promptEncodingFailed)
            }
        } catch {
            showPromptFailure(.promptEncodingFailed)
        }
    }

    private func showPromptFailure(_ failure: IOSPromptCopyFailure) {
        promptCopyNotice = IOSPromptCopyNotice(failure: failure)
    }
}
