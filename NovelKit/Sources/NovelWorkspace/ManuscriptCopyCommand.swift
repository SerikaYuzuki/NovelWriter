import EditorKit
import NovelCore

@MainActor
public protocol WorkspaceManuscriptCopyHost: WorkspaceHost {
    var selectedChapterID: ChapterID? { get }
    var selectedEpisodeID: EpisodeID? { get }
    var manuscriptEditorActive: Bool { get }
    func captureManuscriptText(synchronizeModel: Bool) -> EditorCommittedTextCaptureResult
    func writeManuscriptPlainText(_ text: String) -> Bool
}

public enum ManuscriptCopyRequest {
    case selection(text: String, chapterID: ChapterID, episodeID: EpisodeID)
    case episode(chapterID: ChapterID, episodeID: EpisodeID)
    case chapter(ChapterID)
}

@MainActor
public struct ManuscriptCopyCommand {
    private let host: any WorkspaceManuscriptCopyHost

    public init(host: any WorkspaceManuscriptCopyHost) {
        self.host = host
    }

    public func copy(_ request: ManuscriptCopyRequest, expectedSession: WorkspaceSessionToken?,
                     requireActiveSelection: Bool = true, synchronizeModel: Bool = false,
                     limits: ManuscriptCopyLimits = .standard) -> ManuscriptCopyOutcome {
        let context = host.operationContext
        guard host.permitsLocalMutation, context.session == expectedSession else { return .failure(.staleContext) }
        let source: ManuscriptCopySource
        switch prepare(request, requireActiveSelection: requireActiveSelection, synchronizeModel: synchronizeModel) {
        case let .success(value): source = value
        case let .failure(error): return .failure(error)
        }
        let current = host.operationContext
        guard host.permitsLocalMutation, current.session == context.session, current.workID == context.workID,
              current.account == context.account else { return .failure(.staleContext) }
        do {
            let result = try ManuscriptCopyBuilder.make(source: source, limits: limits)
            return host.writeManuscriptPlainText(result.text) ? .success : .failure(.clipboardWriteFailed)
        } catch ManuscriptCopyError.emptyContent {
            return .failure(.emptyContent)
        } catch is ManuscriptCopyError {
            return .failure(.contentTooLarge)
        } catch {
            return .failure(.copyPreparationFailed)
        }
    }

    private func prepare(_ request: ManuscriptCopyRequest, requireActiveSelection: Bool,
                         synchronizeModel: Bool) -> Result<ManuscriptCopySource, ManuscriptCopyFailure> {
        switch request {
        case let .selection(text, chapterID, episodeID):
            guard host.manuscriptEditorActive, host.selectedChapterID == chapterID, host.selectedEpisodeID == episodeID,
                  host.document.chapters.first(where: { $0.id == chapterID })?.episodes.contains(where: { $0.id == episodeID }) == true else {
                return .failure(.staleContext)
            }
            switch host.captureManuscriptText(synchronizeModel: false) {
            case .compositionInProgress: return .failure(.compositionInProgress)
            case .notActive where requireActiveSelection: return .failure(.staleContext)
            default: return .success(.selection(text: text))
            }
        case let .episode(chapterID, episodeID):
            guard let episode = host.document.chapters.first(where: { $0.id == chapterID })?.episodes.first(where: { $0.id == episodeID }) else {
                return .failure(.staleContext)
            }
            var content = episode.content
            if host.manuscriptEditorActive, host.selectedChapterID == chapterID, host.selectedEpisodeID == episodeID {
                switch host.captureManuscriptText(synchronizeModel: synchronizeModel) {
                case let .captured(text): content = text
                case .compositionInProgress: return .failure(.compositionInProgress)
                case .notActive: break
                }
            }
            return .success(.episode(title: episode.title, content: content))
        case let .chapter(chapterID):
            guard let chapter = host.document.chapters.first(where: { $0.id == chapterID }) else { return .failure(.staleContext) }
            var active: (id: EpisodeID, text: String)?
            if host.manuscriptEditorActive, host.selectedChapterID == chapterID, let selected = host.selectedEpisodeID,
               chapter.episodes.contains(where: { $0.id == selected }) {
                switch host.captureManuscriptText(synchronizeModel: synchronizeModel) {
                case let .captured(text): active = (selected, text)
                case .compositionInProgress: return .failure(.compositionInProgress)
                case .notActive: break
                }
            }
            let episodes = chapter.episodes.map { episode in
                ManuscriptCopyEpisode(title: episode.title, content: active?.id == episode.id ? active?.text ?? episode.content : episode.content)
            }
            return .success(.chapter(title: chapter.title, episodes: episodes))
        }
    }
}
