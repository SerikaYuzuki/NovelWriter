import AppKit
import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import Observation

enum DocumentSaveState: Equatable {
    case unsaved
    case saving
    case saved
    case failed

    var label: String {
        switch self {
        case .unsaved: "未保存"
        case .saving: "保存中"
        case .saved: "この端末に保存済み"
        case .failed: "実エラー"
        }
    }

    var systemImage: String {
        switch self {
        case .unsaved: "circle.fill"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

enum AuthUIState: Equatable {
    case unavailable
    case signedOut
    case signingIn
    case signedIn(accountID: String)
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "アカウント同期は未設定"
        case .signedOut: "未サインイン"
        case .signingIn: "サインイン中…"
        case let .signedIn(accountID): "サインイン済み（\(accountID)）"
        case let .failed(message): message
        }
    }
}

final class NotificationObserverToken {
    private let center: NotificationCenter
    var value: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        if let value {
            center.removeObserver(value)
        }
    }
}

/// The app-level identity used by editor operations. A WorkID may point at a
/// different document payload after remote-only install, keep-both, or an
/// explicit account clone, so it must travel with the session token.
struct AppDocumentSessionToken: Hashable, Sendable {
    var generation: UInt64
    var documentID: UUID
    var workID: WorkID
}

/// Existing editor/outline views use this neutral name for a session-bound
/// value.  It is intentionally the WorkID-backed v2 token; it contains no
/// package URL or other import/export identity.
typealias DocumentSessionToken = AppDocumentSessionToken

@MainActor
@Observable
final class AppState {
    var document: NovelDocument
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var selectedCharacterID: CharacterID?
    var selectedPlotCardID: PlotCardID?
    var selectedFlagID: FlagID?
    var selectedWorldNoteID: WorldNoteID?
    var plotOutlineSelection: PlotOutlineSelection = .unassigned

    var saveState: DocumentSaveState
    var startupState: AppStartupState
    var lastStartupLibraryConnection: StartupLibraryConnection = .offline
    var authSession: FuminiwaSession?
    var authUIState: AuthUIState
    var snapshotSyncV2UIState: SyncUIState?
    var snapshotSyncConflict: SyncV2ConflictProjection?
    var snapshotSyncHistory: [SyncV2HistoryItem] = []
    var snapshotSyncLibraryWorks: [StartupLibraryWork] = []
    var snapshotSyncRemoteCatalogItems: [SyncV2RemoteCatalogEntry] = []
    var snapshotSyncCurrentWorkAccountState: SyncV2LibraryAccountState?
    @ObservationIgnored var snapshotSyncAutoAdoptionTask: Task<Void, Never>?
    var aiClipboardPromptCopyNotice: AIClipboardPromptCopyNotice?
    var isSnapshotSyncInFlight = false
    var externalDocumentOpenErrorMessage: String?
    var operationMessage: String?
    var isDocumentTransitionInProgress = false
    var isTerminationPending = false

    var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    var outlinePresentation = OutlinePresentationState()
    var attachments: [Attachment]
    @ObservationIgnored var snapshotSyncV2Attachments: [SyncAttachment]
    @ObservationIgnored var attachmentPreviewURLs: [String: URL]

    var documentSessionToken: AppDocumentSessionToken
    var editorContentGeneration: UInt64

    let portableBridge: SyncV2PortableBridge
    let userDefaults: UserDefaults
    let fileManager: FileManager
    let defaultDocumentDirectoryName: String
    let editorCommandSession: EditorCommandSession
    let clipboardWriter: any PlainTextClipboardWriting
    let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult
    let authSessionCoordinator: AuthSessionCoordinator?
    let appleSignInCoordinator: AppleSignInCoordinator?
    let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    let snapshotSyncV2Factory: (@Sendable () async throws -> SyncV2Application)?
    let snapshotSyncV2DocumentGate: MacSyncV2DocumentGate?

    @ObservationIgnored var snapshotSyncV2Application: SyncV2Application?
    @ObservationIgnored var snapshotSyncV2Session: NovelSyncV2Application.DocumentSessionToken?
    @ObservationIgnored var snapshotSyncV2ActiveWorkID: WorkID?
    @ObservationIgnored var snapshotSyncV2DocumentCreatedAt: Date?
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored var terminationTask: Task<Bool, Never>?
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var aiClipboardPromptNoticeDismissTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var saveCoordinator: V2DocumentSaveCoordinator!
    @ObservationIgnored let resignActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemSleepObserver = NotificationObserverToken(center: NSWorkspace.shared.notificationCenter)
    @ObservationIgnored let becomeActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemWakeObserver = NotificationObserverToken(center: NSWorkspace.shared.notificationCenter)

    static let projectSectionKey = AppPreferenceKey.projectSection
    static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    var usesSnapshotSyncV2Runtime: Bool {
        snapshotSyncV2Application != nil || snapshotSyncV2Factory != nil
    }

    /// Compatibility names used by old menu wiring are deliberately v2-only.
    var permitsDocumentInteraction: Bool {
        startupState.isReady && !isDocumentTransitionInProgress && !isTerminationPending
    }

    var permitsDocumentChoice: Bool {
        startupState.isReady && !isDocumentTransitionInProgress && !isTerminationPending
    }

    var canExplicitlySyncCurrentWork: Bool {
        permitsDocumentInteraction
    }

    var canCloneCurrentWorkIntoActiveAccount: Bool {
        permitsDocumentInteraction && isSignedInToFuminiwa
            && snapshotSyncCurrentWorkAccountState == .unbound
    }

    var selectedChapter: Chapter? {
        guard let selectedChapterID else { return nil }
        return document.chapters.first { $0.id == selectedChapterID }
    }

    var selectedEpisode: Episode? {
        guard let selectedEpisodeID else { return nil }
        return selectedChapter?.episodes.first { $0.id == selectedEpisodeID }
    }

    init(
        dependencies: AppDependencies,
        initialStartupState: AppStartupState = .loading
    ) {
        portableBridge = dependencies.portableBridge
        userDefaults = dependencies.userDefaults
        fileManager = dependencies.fileManager
        defaultDocumentDirectoryName = dependencies.defaultDocumentDirectoryName
        editorCommandSession = dependencies.editorCommandSession
        clipboardWriter = dependencies.clipboardWriter
        activeCommittedTextCapture = dependencies.activeCommittedTextCapture
        authSessionCoordinator = dependencies.authSessionCoordinator
        appleSignInCoordinator = dependencies.appleSignInCoordinator
        appleAuthenticationOrchestrator = dependencies.appleAuthenticationOrchestrator
        snapshotSyncV2Factory = dependencies.snapshotSyncV2Factory
        snapshotSyncV2DocumentGate = dependencies.snapshotSyncV2DocumentGate

        let placeholder = NovelDocument.newDocument()
        document = placeholder
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = placeholder.chapters.first.map { .chapter($0.id) } ?? .unassigned
        saveState = .unsaved
        startupState = initialStartupState
        authSession = nil
        authUIState = dependencies.authSessionCoordinator == nil ? .unavailable : .signedOut
        externalDocumentOpenErrorMessage = nil
        operationMessage = nil
        attachments = []
        snapshotSyncV2Attachments = []
        attachmentPreviewURLs = [:]
        snapshotSyncLibraryWorks = []
        snapshotSyncRemoteCatalogItems = []
        snapshotSyncCurrentWorkAccountState = nil
        aiClipboardPromptCopyNotice = nil
        documentSessionToken = AppDocumentSessionToken(
            generation: 0,
            documentID: placeholder.id,
            workID: WorkID(UUID())
        )
        editorContentGeneration = 0
        let storedSection = dependencies.userDefaults.string(forKey: Self.projectSectionKey) ?? ""
        let normalizedSection = storedSection == "planning" ? ProjectSection.projectInfo.rawValue : storedSection
        if storedSection == "planning" {
            dependencies.userDefaults.set(normalizedSection, forKey: Self.projectSectionKey)
        }
        workspaceSelection = WorkspaceSelection(
            section: ProjectSection(rawValue: normalizedSection) ?? .structure
        )

        saveCoordinator = V2DocumentSaveCoordinator(
            debounceNanoseconds: Self.autosaveDebounceNanoseconds,
            currentDocument: { [weak self] in
                guard let self, startupState.isReady else { return nil }
                return document
            },
            saveOperation: { [weak self] document in
                guard let self else { throw CancellationError() }
                guard await checkpointSnapshotSyncV2(document, reason: .autosave) else {
                    throw SyncV2Failure.fatal(.invalidLocalState)
                }
            },
            saveEventHandler: { [weak self] event in
                self?.handleSaveEvent(event)
            }
        )

        // Foreground/wake are local lifecycle hints only. They wake the
        // shared outbox in a detached Task and never hold the editor on a
        // network response.
        becomeActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.resumeSnapshotSyncV2()
            }
        }
        systemWakeObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.resumeSnapshotSyncV2()
            }
        }
    }
}
