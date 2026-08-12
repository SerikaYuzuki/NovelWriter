import EditorKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
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

/// `UITextView` callbackを、表示時の作品・話・remote install世代へ固定する。
///
/// 同じworking copy・同じEpisodeIDでもremote headのinstall後は
/// `editorContentGeneration`が変わるため、旧surfaceから遅れて届いた本文を拒否できる。
struct IOSEpisodeEditingToken: Hashable, Sendable {
    let documentSession: IOSDocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
}

struct IOSEditorContentKey: Hashable {
    let documentSession: IOSDocumentSessionToken
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
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
    /// 執筆画面から一覧へ戻る間は、端末保存を待つが全画面の準備表示は出さない。
    /// NavigationStackの戻る操作自体は保存完了まで保留して安全性を維持する。
    var isNavigationDepartureInProgress = false
    private(set) var documentSessionGeneration: UInt64 = 0
    private(set) var editorContentGeneration: UInt64 = 0
    var deviceSyncState: IOSDeviceSyncUIState = .unconfigured
    var deviceSyncTransferState: IOSDeviceSyncTransferState = .notApplicable
    var deviceSyncLocalDurabilityState: IOSDeviceSyncLocalDurabilityState = .notApplicable
    /// 前回processの本文WALを確認するまでだけEditor入力を止める。
    /// remote account/lease/network待ちには使わない。
    var deviceSyncLocalRecoveryPending = false
    var deviceSyncLocalRecoveryReview: IOSDeviceSyncLocalRecoveryReview?
    @ObservationIgnored var deviceSyncLocalRecoveryChoicePending = false
    var deviceSyncConflict: EpisodeConflict?
    var workSyncConflictReview: WorkConflictReview?
    var workSyncLocalRecoveryReview: WorkLocalRecoveryReview?
    var workSyncIsApplyingConflict = false
    var deviceSyncSetupState: IOSDeviceSyncSetupState = .idle
    var libraryItems: [IOSDocumentLibraryItem] = []
    var cloudLibraryItems: [IOSCloudLibraryItem] = []
    var cloudLibraryConnection: IOSCloudLibraryConnection = .offline
    var cloudLibraryIsLoading = false
    private(set) var attachments: [Attachment] = []
    var isImporterPresented = false
    var pendingExportURL: URL?
    var promptCopyNotice: IOSPromptCopyNotice?
    var operationErrorMessage: String?
    private(set) var deviceSyncStartupFailedSafely = false

    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        startupState = .recovery(
            message: "本文同期の安全情報を確認できないため停止しました。アプリを再起動しても直らない場合は、端末の空き容量とiCloud設定を確認してください。"
        )
    }

    let editorCommandSession: EditorCommandSession

    @ObservationIgnored let repository: any DocumentCopyingRepository
    @ObservationIgnored let attachmentManager: (any AttachmentManaging)?
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let libraryRoot: URL
    @ObservationIgnored let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation?
    @ObservationIgnored let backgroundTaskController: any IOSBackgroundTaskControlling
    @ObservationIgnored private let clipboardWriter: any IOSPlainTextClipboardWriting
    @ObservationIgnored let deviceSyncRuntime: IOSDeviceSyncRuntime?
    @ObservationIgnored var deviceSyncClients: [IOSDeviceSyncClientKey: IOSDeviceSyncClient] = [:]
    @ObservationIgnored var activeDeviceSyncIdentity: IOSDeviceSyncEpisodeIdentity?
    @ObservationIgnored var resolvedDeviceSyncLookupIdentity: IOSDeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncDraftTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncEditIntentTask: Task<Void, Never>?
    @ObservationIgnored var pendingDeviceSyncEditIntentMarker: IOSDeviceSyncEditIntentMarker?
    @ObservationIgnored var deviceSyncEditIntentGeneration: UInt64 = 0
    @ObservationIgnored var deviceSyncMutationSequences: [
        IOSDeviceSyncLocalMutationScope: [SyncContentDigest: IOSDeviceSyncLocalMutation]
    ] = [:]
    @ObservationIgnored var deviceSyncDurablePackageDigests: [EpisodeID: SyncContentDigest] = [:]
    @ObservationIgnored var deviceSyncEditIntentLineage: (
        workingCopyIdentity: String,
        episodeID: EpisodeID,
        contentDigest: SyncContentDigest,
        acceptedPriorPackageDigests: [SyncContentDigest]
    )?
    @ObservationIgnored var deviceSyncSignalTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncSignalRefreshTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncSignalRefreshRequested = false
    @ObservationIgnored var deviceSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncPreparationLookup: IOSDeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var pendingDeviceSyncConflictResolution: IOSPendingDeviceSyncConflictResolution?
    @ObservationIgnored var workSyncClient: IOSWorkSyncClient?
    @ObservationIgnored var activeWorkSyncIdentity: IOSWorkSyncIdentity?
    @ObservationIgnored var workSyncNetworkTask: Task<Void, Never>?
    @ObservationIgnored var workSyncNetworkGeneration: UInt64 = 0
    @ObservationIgnored var workSyncNetworkDemandGeneration: UInt64 = 0
    @ObservationIgnored var workSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var workSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var pendingDeviceSyncNewWork: IOSPendingDeviceSyncNewWork?
    @ObservationIgnored var permitsDeviceSyncSelectionMutationAfterFlush = false
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var pendingExportRootURL: URL?
    @ObservationIgnored var verifiedPrivateDocumentIDs: Set<IOSPrivateDocumentID> = []
    @ObservationIgnored var libraryRefreshGeneration: UInt64 = 0
    @ObservationIgnored var cloudLibraryRemoteEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]
    @ObservationIgnored var activeCloudWorkID: SyncWorkID?
    @ObservationIgnored var permitsCloudLibraryMutation = false
    @ObservationIgnored var mayAttemptInitialCloudPublish = false
    @ObservationIgnored var cloudLibraryOperationInProgress = false
    @ObservationIgnored var pendingCloudLibraryRetryTask: Task<Void, Never>?
    @ObservationIgnored var cloudLibraryRefreshTask: Task<Bool, Never>?

    @ObservationIgnored
    lazy var saveCoordinator: DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentState: { [weak self] in
            guard let self, startupState == .ready else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] document, url in
            guard let self else { throw CancellationError() }
            try await performCoordinatedDocumentSave(document, to: url)
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
        attachmentManager: (any AttachmentManaging)? = nil,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any IOSPlainTextClipboardWriting = IOSSystemPlainTextClipboardWriter(),
        deviceSyncRuntime: IOSDeviceSyncRuntime? = nil,
        backgroundTaskController: any IOSBackgroundTaskControlling = IOSApplicationBackgroundTaskController(),
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation? = nil,
        libraryRoot: URL? = nil
    ) {
        self.repository = repository
        self.attachmentManager = attachmentManager ?? (repository as? any AttachmentManaging)
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter
        self.deviceSyncRuntime = deviceSyncRuntime
        self.backgroundTaskController = backgroundTaskController

        let preparedLocation: IOSPrivateWorkingCopyLocation? = if let privateWorkingCopyLocation {
            privateWorkingCopyLocation
        } else if let libraryRoot {
            try? IOSPrivateWorkingCopyLocation.prepareInjectedLibraryRoot(
                libraryRoot,
                fileManager: fileManager
            )
        } else {
            try? IOSPrivateWorkingCopyLocation.prepareDefault(fileManager: fileManager)
        }
        self.privateWorkingCopyLocation = preparedLocation
        let root = preparedLocation?.rootURL
            ?? libraryRoot?.standardizedFileURL
            ?? Self.defaultLibraryRoot(fileManager: fileManager)
        self.libraryRoot = root
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentURL = root.appendingPathComponent("\(placeholder.id.uuidString).novelpkg", isDirectory: true)
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        if preparedLocation == nil {
            failStartupForDeviceSyncSafety()
        }
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
        let previousSelection = (selectedChapterID, selectedEpisodeID)
        guard chapterID == selectedChapterID || permitsSynchronousDeviceSyncSelectionMutation else { return }
        defer {
            if previousSelection != (selectedChapterID, selectedEpisodeID) {
                deviceSyncSelectionDidChange()
            }
        }
        selectedChapterID = chapterID
        guard let chapterID else {
            selectedEpisodeID = nil
            return
        }
        let chapter = document.chapters.first(where: { $0.id == chapterID })
        guard let chapter else {
            selectedEpisodeID = nil
            return
        }
        if !chapter.episodes.contains(where: { $0.id == selectedEpisodeID }) {
            selectedEpisodeID = chapter.episodes.first?.id
        }
    }

    func selectEpisode(_ episodeID: EpisodeID?) {
        guard selectedEpisodeID != episodeID else { return }
        guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        selectedEpisodeID = episodeID
        deviceSyncSelectionDidChange()
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

    func updateEpisodeContent(
        _ content: String,
        chapterID: ChapterID,
        episodeID: EpisodeID,
        expectedEditingToken: IOSEpisodeEditingToken? = nil
    ) {
        if let expectedEditingToken {
            guard currentEpisodeEditingToken == expectedEditingToken else { return }
        }
        guard selectedChapterID == chapterID, selectedEpisodeID == episodeID else { return }
        guard let previousContent = document.episode(episodeID)?.episode.content,
              previousContent != content else { return }
        let baseContentDigest = deviceSyncDurablePackageDigest(
            for: episodeID,
            fallbackContent: previousContent
        )
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        if !usesWholeWorkDeviceSync {
            registerDeviceSyncContentMutation(content, episodeID: episodeID)
        }
        markDocumentChanged()
        if let expectedEditingToken {
            scheduleDeviceSyncForEditedEpisode(
                content: content,
                expectedEditingToken: expectedEditingToken,
                baseContentDigest: baseContentDigest,
                previousContentDigest: SyncContentDigest(content: previousContent)
            )
        }
    }

    func addChapter() {
        guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        let number = document.chapters.count + 1
        let chapterID = document.addChapter(title: "第\(number)章")
        let episodeID = document.addEpisode(to: chapterID)
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        deviceSyncSelectionDidChange()
        markDocumentChanged()
    }

    func addEpisode() {
        guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        guard let selectedChapterID else { return }
        let count = selectedChapter?.episodes.count ?? 0
        let title = count == 0 ? Episode.defaultTitle : "第\(count + 1)話"
        let previousEpisodeID = selectedEpisodeID
        selectedEpisodeID = document.addEpisode(to: selectedChapterID, title: title)
        if selectedEpisodeID != previousEpisodeID {
            deviceSyncSelectionDidChange()
        }
        markDocumentChanged()
    }

    func deleteEpisodes(at offsets: IndexSet, chapterID: ChapterID) {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return }
        let removedIDs = offsets.compactMap { chapter.episodes.indices.contains($0) ? chapter.episodes[$0].id : nil }
        if removedIDs.contains(where: { $0 == selectedEpisodeID }) {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        }
        for episodeID in removedIDs {
            _ = document.removeEpisode(id: episodeID, from: chapterID)
        }
        if removedIDs.contains(where: { $0 == selectedEpisodeID }) {
            selectedEpisodeID = document.chapters
                .first(where: { $0.id == chapterID })?
                .episodes.first?.id
            deviceSyncSelectionDidChange()
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

    private var permitsSynchronousDeviceSyncSelectionMutation: Bool {
        deviceSyncRuntime == nil ||
            activeDeviceSyncIdentity == nil ||
            permitsDeviceSyncSelectionMutationAfterFlush ||
            editorCommandSession.isDocumentTransitionPrepared
    }
}

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
        guard synchronizedSelectedEpisodeForPrompt() != nil else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        guard let chapter = document.chapters.first(where: { $0.id == expectedChapterID }) else {
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
}

extension IOSDocumentStore {
    func markDocumentChanged() {
        guard startupState == .ready, !isDocumentTransitionInProgress else { return }
        if usesWholeWorkDeviceSync, activeWorkSyncIdentity != nil {
            deviceSyncTransferState = .localPending
            deviceSyncLocalDurabilityState = .pending
        }
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    func replaceAttachments(_ attachments: [Attachment]) {
        self.attachments = attachments
    }

    func advanceDocumentSessionGeneration() {
        documentSessionGeneration &+= 1
    }

    func advanceEditorContentGeneration() {
        editorContentGeneration &+= 1
    }
}
