import EditorKit
import Foundation
import NovelCore
import NovelStorage
import Observation

enum IOSStartupState: Equatable {
    case loading
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
    private static let lastDocumentNameKey = "FUMINIWAIOS.lastDocumentName"
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    var document: NovelDocument
    private(set) var documentURL: URL
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    private(set) var startupState: IOSStartupState = .loading
    private(set) var saveState: IOSSaveState = .saved
    private(set) var isDocumentTransitionInProgress = false
    var isImporterPresented = false
    var pendingExportURL: URL?
    var promptCopyNotice: IOSPromptCopyNotice?
    var operationErrorMessage: String?

    let editorCommandSession: EditorCommandSession

    @ObservationIgnored private let repository: any DocumentCopyingRepository
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let libraryRoot: URL
    @ObservationIgnored private let clipboardWriter: any IOSPlainTextClipboardWriting
    @ObservationIgnored private let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var hasCompletedBootstrap = false
    @ObservationIgnored private var pendingExportRootURL: URL?

    @ObservationIgnored
    private lazy var saveCoordinator: DocumentSaveCoordinator = .init(
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

    func bootstrap() async {
        if hasCompletedBootstrap {
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap()
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
        hasCompletedBootstrap = true
    }

    private func performBootstrap() async {
        startupState = .loading
        do {
            try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            if let recentName = userDefaults.string(forKey: Self.lastDocumentNameKey) {
                guard Self.isValidPrivatePackageName(recentName) else {
                    startupState = .recovery(message: "前回の作品情報を安全に解決できませんでした。作品は変更していません。")
                    return
                }
                let recentURL = libraryRoot.appendingPathComponent(recentName, isDirectory: true)
                guard fileManager.fileExists(atPath: recentURL.path) else {
                    startupState = .recovery(message: "前回の作品が見つかりません。原稿を自動的に新規作品へ置き換えてはいません。")
                    return
                }
                let loaded = try await repository.load(from: recentURL)
                install(loaded, at: recentURL)
            } else {
                let initialDocument = NovelDocument.newDocument()
                let initialURL = uniquePackageURL(for: initialDocument.id)
                try await repository.save(initialDocument, to: initialURL)
                install(initialDocument, at: initialURL)
            }
            startupState = .ready
            saveState = .saved
        } catch {
            startupState = .recovery(message: "作品を安全に開けませんでした。元の作品は変更していません。\n\(error.localizedDescription)")
        }
    }

    func makeNewDocument() async {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return }
            await performDocumentTransition {
                let newDocument = NovelDocument.newDocument()
                let newURL = uniquePackageURL(for: newDocument.id)
                try await repository.save(newDocument, to: newURL)
                install(newDocument, at: newURL)
                startupState = .ready
                saveState = .saved
            }
        }
    }

    func importPackage(from sourceURL: URL) async {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return }
            await performDocumentTransition {
                let stagingURL = libraryRoot.appendingPathComponent(
                    ".import-\(UUID().uuidString).novelpkg",
                    isDirectory: true
                )
                let destinationURL = uniquePackageURL(for: UUID())
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    try await Self.copyPackage(from: sourceURL, to: stagingURL)
                    let loaded = try await repository.load(from: stagingURL)
                    try fileManager.moveItem(at: stagingURL, to: destinationURL)
                    install(loaded, at: destinationURL)
                    startupState = .ready
                    saveState = .saved
                } catch {
                    try? fileManager.removeItem(at: stagingURL)
                    try? fileManager.removeItem(at: destinationURL)
                    throw error
                }
            }
        }
    }

    func handleExternalPackageURL(_ url: URL) async {
        await bootstrap()
        await importPackage(from: url)
    }

    private func performDocumentTransition(_ operation: () async throws -> Void) async {
        guard !isDocumentTransitionInProgress else { return }
        isDocumentTransitionInProgress = true
        operationErrorMessage = nil

        guard editorCommandSession.prepareForDocumentTransition() else {
            operationErrorMessage = "日本語入力を確定できませんでした。変換を確定してから、もう一度お試しください。"
            isDocumentTransitionInProgress = false
            return
        }
        defer {
            editorCommandSession.resumeAfterDocumentTransition()
            isDocumentTransitionInProgress = false
        }

        if startupState == .ready {
            guard await saveCoordinator.saveNow() else {
                operationErrorMessage = "現在の作品を保存できなかったため、作品の切り替えを中止しました。"
                return
            }
        }

        do {
            try await operation()
        } catch {
            operationErrorMessage = "作品を開けませんでした。元の作品は変更していません。\n\(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard startupState == .ready else { return false }
        return await saveCoordinator.saveNow()
    }

    func requestExport() async {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return }
            pendingExportURL = nil
            cleanupPendingExport()

            do {
                let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    let root = fileManager.temporaryDirectory
                        .appendingPathComponent("FUMINIWA-Export-\(UUID().uuidString)", isDirectory: true)
                    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                    let filename = Self.portableExportFilename(for: document.title)
                    let destination = root.appendingPathComponent(filename, isDirectory: true)
                    do {
                        try await repository.saveCopy(
                            document,
                            from: documentURL,
                            to: destination
                        )
                        return (root: root, package: destination)
                    } catch {
                        try? fileManager.removeItem(at: root)
                        throw error
                    }
                }

                switch result {
                case .saveFailedBeforeOperation:
                    operationErrorMessage = "保存に失敗したため、書き出しを開始しませんでした。"
                case let .completed(value, savedAfterOperation):
                    guard savedAfterOperation else {
                        try? fileManager.removeItem(at: value.root)
                        operationErrorMessage = "書き出し中の変更を保存できなかったため、中止しました。"
                        return
                    }
                    pendingExportRootURL = value.root
                    pendingExportURL = value.package
                }
            } catch {
                operationErrorMessage = "作品を書き出せませんでした。\n\(error.localizedDescription)"
            }
        }
    }

    func dismissExport() {
        pendingExportURL = nil
        cleanupPendingExport()
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

    private func install(_ document: NovelDocument, at url: URL) {
        self.document = document
        documentURL = url
        selectedChapterID = document.chapters.first?.id
        selectedEpisodeID = document.chapters.first?.episodes.first?.id
        userDefaults.set(url.lastPathComponent, forKey: Self.lastDocumentNameKey)
    }

    private func uniquePackageURL(for id: UUID) -> URL {
        libraryRoot.appendingPathComponent("\(id.uuidString).novelpkg", isDirectory: true)
    }

    private static func defaultLibraryRoot(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("FUMINIWA/Works", isDirectory: true)
    }

    private static func isValidPrivatePackageName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name.hasSuffix(".novelpkg") else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func copyPackage(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value
    }

    static func portableExportFilename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let cleaned = title.unicodeScalars
            .map { forbidden.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "新規作品" : String(cleaned.prefix(80))
        return "\(base).novelpkg"
    }

    private func cleanupPendingExport() {
        guard let pendingExportRootURL else { return }
        try? fileManager.removeItem(at: pendingExportRootURL)
        self.pendingExportRootURL = nil
    }
}
