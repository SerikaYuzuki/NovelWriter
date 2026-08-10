import EditorKit
import Foundation
import NovelCore
import NovelStorage
import Observation

enum IOSStartupState: Equatable {
    case loading
    case library
    case ready
    case recovery(message: String)
}

enum IOSSaveState: Equatable {
    case saved
    case dirty
    case saving
    case failed
}

@MainActor
@Observable
final class IOSDocumentStore {
    static let lastDocumentNameKey = "FUMINIWAIOS.lastDocumentName"
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    var document: NovelDocument
    var documentURL: URL
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var startupState: IOSStartupState = .loading
    var saveState: IOSSaveState = .saved
    var isDocumentTransitionInProgress = false
    var libraryItems: [IOSDocumentLibraryItem] = []
    var isImporterPresented = false
    var pendingExportURL: URL?
    var promptCopyNotice: IOSPromptCopyNotice?
    var operationErrorMessage: String?

    let editorCommandSession: EditorCommandSession

    @ObservationIgnored let repository: any DocumentCopyingRepository
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let libraryRoot: URL
    @ObservationIgnored private let clipboardWriter: any IOSPlainTextClipboardWriting
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var pendingExportRootURL: URL?
    @ObservationIgnored var verifiedPrivateDocumentIDs: Set<IOSPrivateDocumentID> = []
    @ObservationIgnored var libraryRefreshGeneration: UInt64 = 0

    @ObservationIgnored
    lazy var saveCoordinator: DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentState: { [weak self] in
            guard let self, startupState == .ready else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] document, url in
            guard let self else { throw CancellationError() }
            try await repository.save(document, to: url)
        },
        saveEventHandler: { [weak self] event in
            switch event {
            case .dirty:
                self?.saveState = .dirty
            case .saving:
                self?.saveState = .saving
            case .saved:
                self?.saveState = .saved
            case .failed:
                self?.saveState = .failed
            }
        }
    )

    init(
        repository: any DocumentCopyingRepository = NovelpkgRepository(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any IOSPlainTextClipboardWriting = IOSSystemPlainTextClipboardWriter(),
        libraryRoot: URL? = nil
    ) {
        self.repository = repository
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter

        let root = libraryRoot ?? Self.defaultLibraryRoot(fileManager: fileManager)
        self.libraryRoot = root
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentURL = root.appendingPathComponent("\(placeholder.id.uuidString).novelpkg", isDirectory: true)
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
    }

    var selectedChapter: Chapter? {
        guard let selectedChapterID else { return nil }
        return document.chapters.first(where: { $0.id == selectedChapterID })
    }

    var selectedEpisode: Episode? {
        guard let selectedChapter, let selectedEpisodeID else { return nil }
        return selectedChapter.episodes.first(where: { $0.id == selectedEpisodeID })
    }

    func selectChapter(_ chapterID: ChapterID?) {
        selectedChapterID = chapterID
        guard let chapterID,
              let chapter = document.chapters.first(where: { $0.id == chapterID }) else
        {
            selectedEpisodeID = nil
            return
        }
        if !chapter.episodes.contains(where: { $0.id == selectedEpisodeID }) {
            selectedEpisodeID = chapter.episodes.first?.id
        }
    }

    func selectEpisode(_ episodeID: EpisodeID?) {
        selectedEpisodeID = episodeID
    }

    func updateDocumentTitle(_ title: String) {
        guard document.title != title else { return }
        document.title = title
        markDocumentChanged()
    }

    func updateDocumentSynopsis(_ synopsis: String) {
        guard document.synopsis != synopsis else { return }
        document.synopsis = synopsis
        markDocumentChanged()
    }

    func updateChapterTitle(_ title: String, chapterID: ChapterID) {
        guard document.chapters.first(where: { $0.id == chapterID })?.title != title else { return }
        document.updateTitle(title, for: chapterID)
        markDocumentChanged()
    }

    func updateEpisodeTitle(_ title: String, chapterID: ChapterID, episodeID: EpisodeID) {
        guard document.episode(episodeID)?.episode.title != title else { return }
        document.updateEpisodeTitle(title, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

    func updateEpisodeContent(_ content: String, chapterID: ChapterID, episodeID: EpisodeID) {
        guard selectedChapterID == chapterID, selectedEpisodeID == episodeID else { return }
        guard document.episode(episodeID)?.episode.content != content else { return }
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

    func addChapter() {
        let number = document.chapters.count + 1
        let chapterID = document.addChapter(title: "第\(number)章")
        let episodeID = document.addEpisode(to: chapterID)
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        markDocumentChanged()
    }

    func addEpisode() {
        guard let selectedChapterID else { return }
        let count = selectedChapter?.episodes.count ?? 0
        let title = count == 0 ? Episode.defaultTitle : "第\(count + 1)話"
        selectedEpisodeID = document.addEpisode(to: selectedChapterID, title: title)
        markDocumentChanged()
    }

    func deleteEpisodes(at offsets: IndexSet, chapterID: ChapterID) {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return }
        let removedIDs = offsets.compactMap { chapter.episodes.indices.contains($0) ? chapter.episodes[$0].id : nil }
        for episodeID in removedIDs {
            _ = document.removeEpisode(id: episodeID, from: chapterID)
        }
        if removedIDs.contains(where: { $0 == selectedEpisodeID }) {
            selectedEpisodeID = document.chapters
                .first(where: { $0.id == chapterID })?
                .episodes.first?.id
        }
        markDocumentChanged()
    }

    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
    }

    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        document.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
    }

    func updateEpisodeMemo(_ memo: String, chapterID: ChapterID, episodeID: EpisodeID) {
        guard document.episode(episodeID)?.episode.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

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
        guard selectedEpisodeID == expectedEpisodeID,
              let episode = synchronizedSelectedEpisodeForPrompt() else
        {
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
              let chapter = document.chapters.first(where: { $0.id == expectedChapterID }) else
        {
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
            case .emptyContent:
                showPromptFailure(.emptyContent)
            case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .promptUTF8ByteLimitExceeded:
                showPromptFailure(.contentTooLarge)
            case .encodingFailed:
                showPromptFailure(.promptEncodingFailed)
            }
        } catch {
            showPromptFailure(.promptEncodingFailed)
        }
    }

    private func showPromptFailure(_ failure: IOSPromptCopyFailure) {
        promptCopyNotice = IOSPromptCopyNotice(failure: failure)
    }

    private func markDocumentChanged() {
        guard startupState == .ready, !isDocumentTransitionInProgress else { return }
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }
}
