import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelSync
import Observation

enum DocumentSaveState: Equatable {
    case unsaved
    case saving
    case saved
    case failed

    var label: String {
        switch self {
        case .unsaved:
            "未保存"
        case .saving:
            "保存中"
        case .saved:
            "保存済み"
        case .failed:
            "保存に失敗しました"
        }
    }

    var systemImage: String {
        switch self {
        case .unsaved:
            "circle.fill"
        case .saving:
            "arrow.triangle.2.circlepath"
        case .saved:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }
}

/// 「別名で保存」の利用者向け結果。保存状態や現在sessionを後から推測せず、
/// URL切替を確定した同じライフサイクル操作から事実を返す。
enum SaveDocumentAsResult: Equatable {
    case saved
    case staleSession
    case failedBeforeSwitch
    case switchedButLatestEditsFailed
}

/// AppStateのactor分離に依存せず、破棄時に通知登録を解除するtoken holder。
private final class NotificationObserverToken {
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

private struct StartupVerifiedLocalLibraryItem {
    let record: DeviceSyncLocalLibraryRecord?
    let attestation: DeviceSyncLocalPackageAttestation?
    let row: StartupLibraryWork
}

private struct StartupVerifiedLocalLibrarySnapshot {
    let items: [SyncWorkID: StartupVerifiedLocalLibraryItem]

    var rows: [StartupLibraryWork] {
        items.values.map(\.row)
    }
}

struct PendingPrivateLibraryPublication {
    let workID: SyncWorkID
    let document: NovelDocument
    let packageURL: URL
    let mayAttemptInitialPublish: Bool
}

/// アプリ全体の状態を管理する(docs/DESIGN.md 5.2)。
///
/// 責務:
/// - 現在開いている作品(`document`)と選択中の章／話IDの保持
/// - 選択中話の取得・本文更新(ロジック自体は `NovelDocument` のヘルパーに委譲し、
///   `AppState` は薄く保つ)
/// - 保存先 URL の保持と、「最近開いた作品」のファイルパスの記録(D-009。
///   App Sandbox 非採用のためセキュリティスコープ付きブックマークは不要 → D-011)
/// - 自動保存: 本文変更は2秒デバウンス、話切り替え時とアプリ非アクティブ時は即保存
///   (docs/DESIGN.md 6.4)
@MainActor
@Observable
final class AppState {
    /// 現在開いている作品。
    private(set) var document: NovelDocument
    /// 選択中の章ID。`Chapter` そのものではなく ID で管理する(docs/DESIGN.md 5.2)。
    private(set) var selectedChapterID: ChapterID?
    /// 選択中の話ID。本文編集の選択キーは話単位で管理する(D-028)。
    private(set) var selectedEpisodeID: EpisodeID?
    /// 選択中の登場人物ID。
    private(set) var selectedCharacterID: CharacterID?
    /// 選択中のプロットカードID。
    private(set) var selectedPlotCardID: PlotCardID?
    /// 選択中の伏線ID。
    private(set) var selectedFlagID: FlagID?
    /// 選択中の世界観ノートID。
    private(set) var selectedWorldNoteID: WorldNoteID?
    /// プロット画面 content 列の選択。未割り当てと章を切り替える(UIFIX 4.2)。
    private(set) var plotOutlineSelection: PlotOutlineSelection = .unassigned
    /// 原稿パッケージの保存状態。表示はこの値だけを正とする。
    private(set) var saveState: DocumentSaveState
    /// 起動中の編集可能placeholderをUIへ露出しないための三状態(D-039)。
    private(set) var startupState: AppStartupState
    /// account identityを確認できた時だけnew/importをcloud workとして開始する。
    private(set) var permitsCloudLibraryMutation = false
    /// 直近の作品棚connection。Workbenchの「iCloudに保存」はchooserを離れたあともこれを見る。
    private(set) var lastStartupLibraryConnection: StartupLibraryConnection = .offline
    /// 現在作品がこのaccountへbind済みなら明示保存は出さない。
    var isCurrentWorkBoundToCloud = false
    /// production syncのlocal metadataを確立できなかったprocessは、
    /// Finder Openや新規作成でruntime-nil writerへ復帰させない。
    private(set) var deviceSyncStartupFailedSafely = false
    /// Finderからの作品オープンに失敗したときだけ使う安全な利用者向け文言。
    var externalDocumentOpenErrorMessage: String?
    /// 作品棚の明示操作（iCloudへ保存／複製／削除）のpath-free結果。
    var cloudLibraryActionMessage: String?
    /// clipboardへ送った本文を保持せず、直近のcopy結果だけを表示する一時通知。
    private(set) var aiClipboardPromptCopyNotice: AIClipboardPromptCopyNotice?

    /// Project Sidebar と Outline の選択状態。UI2 以降の画面選択の正。
    private(set) var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    /// Outline の検索バーなど、表示専用の一時状態。
    var outlinePresentation = OutlinePresentationState()
    /// 現在の作品に取り込まれている資料一覧。
    private(set) var attachments: [Attachment]
    /// 現在の保存先 URL(`.novelpkg` パッケージ)。
    private(set) var documentURL: URL
    /// 非同期UI操作が、呼び出し元と同じ作品を対象にしているか確認する世代値。
    private(set) var documentSessionToken: DocumentSessionToken
    /// EditorViewへ本文を再流込する世代。作品install/復元時だけ進め、
    /// 同じ本文を保つ別名保存ではcaretとUndoを維持する。
    private(set) var editorContentGeneration: UInt64
    /// 選択中話のDevice Sync表示と本文編集権限。
    var deviceSyncState: DeviceSyncUIState
    var deviceSyncTransferState: DeviceSyncTransferState
    var deviceSyncLocalDurabilityState: DeviceSyncLocalDurabilityState
    /// 前回processの本文WALを確認するまでだけEditor入力を止める。
    /// remote account/lease/network待ちには使わない。
    var deviceSyncLocalRecoveryPending = false
    var deviceSyncLocalRecoveryReview: DeviceSyncLocalRecoveryReview?
    @ObservationIgnored var deviceSyncLocalRecoveryChoicePending = false
    var deviceSyncConflict: EpisodeConflict?
    var deviceSyncSetupState: DeviceSyncSetupState = .idle
    /// D-061作品同期の競合。本文Editorへremoteを注入せず、明示sheetでだけ選ばせる。
    var workSyncConflictReview: WorkConflictReview?
    var workSyncLocalRecoveryReview: WorkLocalRecoveryReview?
    var isApplyingWorkSyncConflict = false
    var noteSyncConflict: NoteSyncConflict?

    private let repository: DocumentRepository
    private let attachmentManager: AttachmentManaging?
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let defaultDocumentDirectoryName: String
    /// 表示中のEditorKitへ、作品遷移前のIME確定・モデル同期・入力停止を依頼する。
    let editorCommandSession: EditorCommandSession
    /// promptをsystem clipboardへ書く、テスト差し替え可能な境界。
    private let clipboardWriter: any PlainTextClipboardWriting
    /// active Editorから確定済み本文だけを読み取る。IME変換中は本文を返さない。
    private let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult
    @ObservationIgnored let deviceSyncRuntime: DeviceSyncRuntime?
    @ObservationIgnored var deviceSyncClients: [DeviceSyncClientKey: DeviceSyncClient] = [:]
    @ObservationIgnored var activeDeviceSyncIdentity: DeviceSyncEpisodeIdentity?
    @ObservationIgnored var resolvedDeviceSyncLookupIdentity: DeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncDraftTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncEditIntentTask: Task<Void, Never>?
    @ObservationIgnored var pendingDeviceSyncEditIntentMarker: DeviceSyncEditIntentMarker?
    @ObservationIgnored var deviceSyncEditIntentGeneration: UInt64 = 0
    @ObservationIgnored var deviceSyncMutationSequences: [
        DeviceSyncLocalMutationScope: [SyncContentDigest: DeviceSyncLocalMutation]
    ] = [:]
    @ObservationIgnored var deviceSyncDurablePackageDigests: [EpisodeID: SyncContentDigest] = [:]
    @ObservationIgnored var deviceSyncEditIntentLineage: (
        workingCopyIdentity: String,
        episodeID: EpisodeID,
        contentDigest: SyncContentDigest,
        acceptedPriorPackageDigests: [SyncContentDigest]
    )?
    @ObservationIgnored var deviceSyncSignalTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncPreparationLookup: DeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var pendingDeviceSyncConflictResolution: PendingDeviceSyncConflictResolution?
    @ObservationIgnored var pendingDeviceSyncNewWork: PendingDeviceSyncNewWork?
    @ObservationIgnored var activeWorkSyncIdentity: WorkSyncDocumentIdentity?
    @ObservationIgnored var workSyncClient: WorkSyncClient?
    @ObservationIgnored var noteSyncClient: NoteSyncClient?
    @ObservationIgnored var workSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var workSyncPreparationIdentity: WorkSyncPreparationIdentity?
    @ObservationIgnored var workSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var workSyncNetworkTask: Task<Void, Never>?
    @ObservationIgnored var workSyncNetworkRescheduleRequested = false
    @ObservationIgnored var workSyncRemoteBindingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLibraryPublishTasks: [SyncWorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingLibraryRetryTask: Task<Void, Never>?
    @ObservationIgnored var mayAttemptInitialCloudPublish = false
    @ObservationIgnored var permitsDeviceSyncSelectionMutationAfterFlush = false
    @ObservationIgnored var permitsDeviceSyncProjectSectionMutationAfterFlush = false
    /// 作品の切替・復元・資料操作など、高レベルの状態遷移を`await`越しに直列化する。
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    /// 終了前保存を要求した後に、新しい作品遷移を開始させない。
    @ObservationIgnored private var isTerminationPending = false
    /// 重複した終了要求を同じ保存結果へ合流させるsingle-flight Task。
    @ObservationIgnored private var terminationTask: Task<Bool, Never>?
    /// copy結果の通知を一定時間後に閉じるTask。prompt本文は捕捉しない。
    @ObservationIgnored private var aiClipboardPromptNoticeDismissTask: Task<Void, Never>?
    /// 最終入力確定後から保存・install完了まで、旧UIからのdocument変更を拒否する。
    private(set) var isDocumentTransitionInProgress = false
    /// chooserからのopen/new/importを一件だけにし、準備中をUIへ明示する。
    var isStartupLibraryOperationInProgress = false
    /// 章をまたいで戻ったときに復元する、章ごとの最後の話選択。
    @ObservationIgnored
    private var lastSelectedEpisodeByChapter: [ChapterID: EpisodeID] = [:]

    /// 保存要求の直列化を担う(D-017)。`document` / `documentURL` の最新値を
    /// クロージャ越しに参照するため、`self` を弱参照で捕捉できるよう `lazy` にする
    /// (`init` の途中で `self` を捕捉すると「全プロパティ初期化前に self を使った」
    /// エラーになるため。`lazy` なら初回アクセス時点で初期化が完了している)。
    /// `@Observable` の観測対象からは外す(UIの再描画とは無関係な内部実装)。
    @ObservationIgnored
    lazy var saveCoordinator: DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentState: { [weak self] in
            guard let self, startupState.isReady else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] doc, url in
            guard let self else { throw CancellationError() }
            try await performCoordinatedDocumentSave(doc, to: url)
        },
        saveEventHandler: { [weak self] event in
            self?.handleSaveEvent(event)
        }
    )

    private func performCoordinatedDocumentSave(
        _ document: NovelDocument,
        to url: URL
    ) async throws {
        do {
            let workPreparation = await stageWorkSyncPackageSave(document)
            switch workPreparation {
            case .notApplicable:
                break
            case .failed:
                // journalが失敗しても、利用者の原稿はpackageへ退避する。
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                _ = await recordLocalLibraryPackageSave(document, at: url)
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                return
            case let .prepared(preparation):
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                guard await recordLocalLibraryPackageSave(document, at: url) else {
                    deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                    return
                }
                await confirmWorkSyncPackageSave(preparation)
                return
            case let .notePrepared(preparation):
                try await repository.save(document, to: url)
                noteDeviceSyncPackageSaved(document)
                guard await recordLocalLibraryPackageSave(document, at: url) else {
                    deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                    return
                }
                await confirmNoteSyncPackageSave(preparation)
                return
            }
            let intentReady = await flushPendingDeviceSyncEditIntents()
            let checkpoints = await prepareDeviceSyncPackageCheckpoints(for: document, at: url)
            try await repository.save(document, to: url)
            noteDeviceSyncPackageSaved(document)
            guard await recordLocalLibraryPackageSave(document, at: url) else {
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                return
            }
            let checkpointsCommitted = await commitDeviceSyncPackageCheckpoints(checkpoints)
            if !intentReady || !checkpoints.allPrepared || !checkpointsCommitted {
                deviceSyncLocalDurabilityState = .failed
            }
        } catch {
            // 保存失敗でアプリを落とさない。まずはログのみ残し、執筆継続を優先する。
            print("[FUMINIWA] 保存に失敗しました(\(Self.errorCategory(error)))")
            throw error
        }
    }

    /// App-private packageのreadback exactを確認してからlocal library recordを更新する。
    /// Work journalのmaterialization confirmより先に耐久化し、registry失敗時はremote
    /// confirmを止めることでfalse checkmarkと未追跡uploadを防ぐ。
    private func recordLocalLibraryPackageSave(
        _ expectedDocument: NovelDocument,
        at url: URL
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return true }
        do {
            guard let workID = try await library.workIDForPackageURL(url) else { return true }
            try await library.validateInstalledPackage(workID)
            guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                return false
            }
            let readBack = try await portableRepository.validatePortablePackage(at: url)
            guard readBack == expectedDocument,
                  try WorkSnapshot(document: readBack) == WorkSnapshot(document: expectedDocument) else {
                return false
            }
            let attestation = try DeviceSyncLocalPackageAttestation(
                document: readBack,
                updatedAt: runtime.now()
            )
            try await library.recordPackageMutation(workID, attestation)
            return true
        } catch {
            return false
        }
    }

    /// holderのdeinitで一度だけ解除するアプリ非アクティブ通知のtoken。
    @ObservationIgnored private let resignActiveObserver = NotificationObserverToken()
    /// スリープ直前にIME・package・journalを確定するworkspace通知のtoken。
    @ObservationIgnored private let systemSleepObserver = NotificationObserverToken(
        center: NSWorkspace.shared.notificationCenter
    )
    /// pushが欠落してもforeground/wakeでexact fenceを再検査する。
    @ObservationIgnored private let becomeActiveObserver = NotificationObserverToken()
    @ObservationIgnored private let systemWakeObserver = NotificationObserverToken(
        center: NSWorkspace.shared.notificationCenter
    )
    /// SwiftUIのtask再評価で同時に呼ばれたbootstrapを、同じ完了へ合流させる。
    /// 単なるstartedフラグでは後続呼び出しだけが先にreturnできるため、実行中Taskを保持する。
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var hasCompletedBootstrap = false
    /// 初回I/O中に別のtaskが受け取ったFinder URL。初回処理の後に同じTask内で開く。
    @ObservationIgnored private var pendingBootstrapOpenURL: URL?
    /// remote-only rowを開くときに、表示したexact head以外を採用しないためのfence。
    @ObservationIgnored private var startupRemoteLibraryEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]
    /// foreground/signal/manual refreshの旧結果が、別accountや新しい棚を上書きしない。
    @ObservationIgnored private var startupLibraryRefreshGeneration: UInt64 = 0
    /// remote catalog refreshは同一作品棚のsingle-flightへ合流させる。
    @ObservationIgnored private var startupLibraryRefreshTask: Task<Void, Never>?

    private static let recentDocumentPathKey = AppPreferenceKey.recentDocumentPath
    private static let projectSectionKey = AppPreferenceKey.projectSection
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    init(
        dependencies: AppDependencies,
        initialStartupState: AppStartupState = .loading
    ) {
        repository = dependencies.repository
        attachmentManager = dependencies.attachmentManager
        userDefaults = dependencies.userDefaults
        fileManager = dependencies.fileManager
        defaultDocumentDirectoryName = dependencies.defaultDocumentDirectoryName
        editorCommandSession = dependencies.editorCommandSession
        clipboardWriter = dependencies.clipboardWriter
        activeCommittedTextCapture = dependencies.activeCommittedTextCapture
        deviceSyncRuntime = dependencies.deviceSyncRuntime
        deviceSyncTransferState = .notApplicable
        deviceSyncLocalDurabilityState = .notApplicable

        // 実際の状態は `bootstrap()` で確立する。ここでは(ウィンドウ表示を
        // ブロックしないよう)空の新規作品をプレースホルダとして持たせておく。
        let placeholder = NovelDocument.newDocument()
        let placeholderURL = Self.defaultSaveURL(
            forTitle: placeholder.title,
            fileManager: dependencies.fileManager,
            directoryName: dependencies.defaultDocumentDirectoryName
        )
        document = placeholder
        documentURL = placeholderURL
        documentSessionToken = DocumentSessionToken(
            generation: 0,
            documentID: placeholder.id,
            documentURL: placeholderURL.standardizedFileURL
        )
        editorContentGeneration = 0
        deviceSyncState = .unconfigured
        deviceSyncConflict = nil
        workSyncConflictReview = nil
        noteSyncConflict = nil
        workSyncLocalRecoveryReview = nil
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = placeholder.chapters.first.map { .chapter($0.id) } ?? .unassigned
        saveState = .unsaved
        startupState = initialStartupState
        permitsCloudLibraryMutation = deviceSyncRuntime == nil
        externalDocumentOpenErrorMessage = nil
        aiClipboardPromptCopyNotice = nil
        let storedSection = dependencies.userDefaults.string(forKey: Self.projectSectionKey) ?? ""
        let initialSection: ProjectSection = if storedSection == "planning" {
            .projectInfo
        } else {
            ProjectSection(rawValue: storedSection) ?? .structure
        }
        workspaceSelection = WorkspaceSelection(
            section: initialSection
        )
        if storedSection == "planning" {
            dependencies.userDefaults.set(ProjectSection.projectInfo.rawValue, forKey: Self.projectSectionKey)
        }
        attachments = []
    }

    /// 起動時の作品選択またはFinder指定作品の読み込みを行う。SwiftUIのtask再評価による同時呼び出しは
    /// 一つの実行と完了へ合流する。
    ///
    /// 通常起動では前回作品を自動で開かず、利用者が明示的に選ぶ画面で停止する。
    /// Finderから指定されたURLはその選択自体を尊重して直接開く。読込失敗時は
    /// 新規作品へfallbackせずRecoveryで停止し、原稿とrecent URLを変更しない(D-039 / D-062)。
    func bootstrap(opening requestedURL: URL? = nil, localFirst: Bool = false) async {
        guard !deviceSyncStartupFailedSafely else { return }
        if hasCompletedBootstrap {
            if let requestedURL {
                _ = await openExternalDocument(at: requestedURL)
            }
            return
        }

        if let requestedURL {
            pendingBootstrapOpenURL = requestedURL
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let initialOpenURL = pendingBootstrapOpenURL
        pendingBootstrapOpenURL = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap(opening: initialOpenURL, localFirst: localFirst)
        }
        bootstrapTask = task
        await task.value
    }

    /// 初回状態の確立と、そのI/O中に届いたFinder openを一つの完了境界として処理する。
    /// これにより、どの`bootstrap()`呼び出しもdelegateへ早すぎる完了を返さない。
    private func performBootstrap(opening requestedURL: URL?, localFirst: Bool) async {
        guard !deviceSyncStartupFailedSafely else { return }
        observeResignActive()
        observeSystemSleep()
        observeDeviceSyncReactivation()
        startDeviceSyncSignalObservationIfNeeded()

        await establishInitialStartupState(opening: requestedURL, localFirst: localFirst)

        while let pendingOpenURL = pendingBootstrapOpenURL {
            pendingBootstrapOpenURL = nil
            _ = await openExternalDocument(at: pendingOpenURL)
        }

        hasCompletedBootstrap = true
        bootstrapTask = nil
        if localFirst {
            scheduleStartupLibraryRemoteRefreshIfNeeded()
        }
    }

    private func establishInitialStartupState(opening requestedURL: URL?, localFirst: Bool) async {
        if deviceSyncRuntime?.library != nil {
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .available,
                    isLoading: true
                )
            )
            if localFirst {
                await refreshLocalStartupLibrary()
                if let requestedURL {
                    _ = await importExternalDocument(at: requestedURL, expectedSession: documentSessionToken)
                }
            } else if let requestedURL {
                await refreshStartupLibrary()
                _ = await importExternalDocument(at: requestedURL, expectedSession: documentSessionToken)
            } else {
                await refreshStartupLibrary()
            }
            return
        }
        if let requestedURL {
            await loadStartupDocument(at: requestedURL, source: .finder)
            return
        }

        let recentDocumentURL = userDefaults.string(forKey: Self.recentDocumentPathKey)
            .flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path)
            }
        startupState = .documentSelection(
            StartupDocumentSelectionContext(recentDocumentURL: recentDocumentURL)
        )
    }

    /// CloudKitを待たず、検証済みの端末内inventoryだけで作品棚を表示する。
    /// ここがmacOSのforeground/startup laneの完了境界であり、remote catalogは
    /// このメソッドの後に別Taskで開始する。
    @discardableResult
    private func refreshLocalStartupLibrary() async -> Bool {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              case let .documentSelection(current) = startupState,
              current.presentation == .cloudLibrary else { return false }

        startupLibraryRefreshGeneration &+= 1
        let generation = startupLibraryRefreshGeneration
        let expectedSession = documentSessionToken
        if current.works.isEmpty {
            permitsCloudLibraryMutation = false
        }
        mayAttemptInitialCloudPublish = false

        do {
            let local = try await loadVerifiedLocalLibrary(using: library, now: runtime.now())
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return false
            }
            let resumableWorkIDs = await library.offlineResumableRemoteOpenWorkIDs()
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return false
            }
            permitsCloudLibraryMutation = true
            startupRemoteLibraryEntries = [:]
            lastStartupLibraryConnection = current.connection
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: Self.addOfflineResumableRows(
                        resumableWorkIDs,
                        to: local.rows
                    ).sorted(by: Self.startupLibrarySort),
                    connection: current.connection,
                    isLoading: false
                )
            )
            return true
        } catch {
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return false
            }
            permitsCloudLibraryMutation = false
            startupRemoteLibraryEntries = [:]
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .unavailable(message: "このMacの作品情報を安全に確認できませんでした。")
                )
            )
            return false
        }
    }

    /// cached rowsを先に残し、remote refreshは同じ棚へmergeする。標準runtimeで
    /// recent path fallbackを一瞬でも表示しない。
    func refreshStartupLibrary() async {
        if let startupLibraryRefreshTask {
            await startupLibraryRefreshTask.value
        }
        if let startupLibraryRefreshTask {
            await startupLibraryRefreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performStartupLibraryRefresh()
        }
        startupLibraryRefreshTask = task
        await task.value
        startupLibraryRefreshTask = nil
    }

    private func scheduleStartupLibraryRemoteRefreshIfNeeded() {
        guard deviceSyncRuntime?.library != nil,
              case let .documentSelection(context) = startupState,
              context.presentation == .cloudLibrary,
              startupLibraryRefreshTask == nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshStartupLibrary()
        }
    }

    /// Remote catalog is deliberately a background lane. The verified local
    /// shelf remains visible and usable for the whole duration of this method.
    private func performStartupLibraryRefresh() async {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              case let .documentSelection(current) = startupState,
              current.presentation == .cloudLibrary else { return }

        startupLibraryRefreshGeneration &+= 1
        let generation = startupLibraryRefreshGeneration
        let expectedSession = documentSessionToken
        let priorRows = current.works
        // A previously verified local shelf remains writable while this remote
        // refresh is in flight. Only an actual local verification failure
        // revokes the local mutation capability below.
        if priorRows.isEmpty {
            permitsCloudLibraryMutation = false
        }
        mayAttemptInitialCloudPublish = false
        startupState = .documentSelection(
            StartupDocumentSelectionContext(
                works: priorRows,
                connection: current.connection,
                isLoading: false
            )
        )

        let local: StartupVerifiedLocalLibrarySnapshot
        do {
            local = try await loadVerifiedLocalLibrary(using: library, now: runtime.now())
        } catch {
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            permitsCloudLibraryMutation = false
            startupRemoteLibraryEntries = [:]
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    // root/registry validation failureは旧accountのremote titleも含め
                    // fail-closedで破棄し、端末内packageを確認できたとはclaimしない。
                    works: [],
                    connection: .unavailable(message: "このMacの作品情報を安全に確認できませんでした。")
                )
            )
            return
        }

        guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
            return
        }
        startupState = .documentSelection(
            StartupDocumentSelectionContext(
                works: local.rows.sorted(by: Self.startupLibrarySort),
                connection: current.connection,
                isLoading: false
            )
        )

        // Local inventory has been verified. Local new/import may proceed even
        // while the account and remote catalog are unavailable.
        permitsCloudLibraryMutation = true

        let resumableWorkIDs = await library.offlineResumableRemoteOpenWorkIDs()
        guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
            return
        }

        do {
            var remote = try await library.loadRemoteLibrary()
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            guard startupLibraryRefreshIsCurrent(
                generation,
                expectedSession: expectedSession
            ) else { return }
            let didPublish = await retryAccountScopedPendingPublications(
                local: local,
                remote: remote,
                library: library
            )
            if didPublish {
                remote = try await library.loadRemoteLibrary()
                guard startupLibraryRefreshIsCurrent(
                    generation,
                    expectedSession: expectedSession
                ) else { return }
            }
            // local inventoryとaccount状態を同じrefresh generationで確認した後だけ
            // new/importを許可する。accountRequiredでもlocal-only作成は可能だが、
            // initial publishは別accountへ漏らさない。
            permitsCloudLibraryMutation = true
            mayAttemptInitialCloudPublish = remote.connection == .available
                || remote.connection == .offline
            lastStartupLibraryConnection = Self.startupConnection(remote.connection)
            let merged = await mergeStartupLibrary(
                local: local,
                remote: remote,
                resumableWorkIDs: resumableWorkIDs,
                library: library
            )
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: merged.sorted(by: Self.startupLibrarySort),
                    connection: Self.startupConnection(remote.connection)
                )
            )
        } catch {
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            startupRemoteLibraryEntries = [:]
            // local inventory/rootはこのgenerationで検証済み。remote catalogの
            // 読込失敗はuploadを止めるが、端末内の新規・Importまで止めない。
            permitsCloudLibraryMutation = true
            mayAttemptInitialCloudPublish = false
            lastStartupLibraryConnection = .unavailable(
                message: "iCloudの作品を更新できませんでした。"
            )
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: Self.addOfflineResumableRows(
                        resumableWorkIDs,
                        to: local.rows
                    ).sorted(by: Self.startupLibrarySort),
                    connection: lastStartupLibraryConnection
                )
            )
        }
    }

    private func startupLibraryRefreshIsCurrent(
        _ generation: UInt64,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard startupLibraryRefreshGeneration == generation,
              documentSessionToken == expectedSession,
              case let .documentSelection(context) = startupState,
              context.presentation == .cloudLibrary else { return false }
        return true
    }

    private func loadVerifiedLocalLibrary(
        using library: DeviceSyncLibraryRuntime,
        now: Date
    ) async throws -> StartupVerifiedLocalLibrarySnapshot {
        let inventory = try await library.loadLocalInventory()
        var items: [SyncWorkID: StartupVerifiedLocalLibraryItem] = [:]

        for storedRecord in inventory.records {
            let record = await repairReservedLibraryWorkIfPossible(
                storedRecord,
                library: library
            )
            items[record.workID] = await verifyLocalLibraryRecord(
                record,
                library: library,
                now: now
            )
        }
        let isolated = inventory.unreadableWorkIDs
            .union(inventory.unregisteredPackageWorkIDs)
            .subtracting(items.keys)
        for workID in isolated {
            let title = await localLibraryPackageTitle(
                workID: workID,
                library: library,
                now: now
            )
            items[workID] = StartupVerifiedLocalLibraryItem(
                record: nil,
                attestation: title.attestation,
                row: StartupLibraryWork(
                    reference: .cloudWork(workID.rawValue),
                    title: title.attestation?.titleProjection ?? "確認が必要な作品",
                    updatedAt: title.attestation?.updatedAt,
                    availability: .unavailable,
                    isTitleTruncated: title.attestation.map {
                        $0.fullTitleUTF8ByteCount > $0.titleProjection.utf8.count
                    } ?? false
                )
            )
        }
        return StartupVerifiedLocalLibrarySnapshot(items: items)
    }

    /// staging attestation→RENAME_EXCL→confirmの各kill窓を、同じexact packageだけで
    /// 再開する。証明できないpackage/stagingは触らずdisabled行に残す。
    private func repairReservedLibraryWorkIfPossible(
        _ record: DeviceSyncLocalLibraryRecord,
        library: DeviceSyncLibraryRuntime
    ) async -> DeviceSyncLocalLibraryRecord {
        guard record.state == .reservedForPublish,
              let portableRepository = repository as? PortableDocumentPackageRepository else {
            return record
        }
        do {
            // D-063 より前の作成途中レコードは期待した作品内容を証明できない。
            // 同じ document ID だけで staging を採用せず、保全対象として隔離する。
            guard let attestation = record.package else { return record }

            let finalURL = try await library.packageURL(record.workID)
            if await (try? library.validateInstalledPackage(record.workID)) == nil {
                let staging = try await library.stagingPackageURL(record.workID)
                try await library.validateStagingPackage(staging, record.workID)
                let staged = try await portableRepository.validatePortablePackage(at: staging)
                let stagedAttestation = try DeviceSyncLocalPackageAttestation(
                    document: staged,
                    updatedAt: attestation.updatedAt
                )
                guard stagedAttestation == attestation else { return record }
                let installed = try await library.installStagingPackage(staging, record.workID)
                guard installed == finalURL else { return record }
            }

            try await library.validateInstalledPackage(record.workID)
            let final = try await portableRepository.validatePortablePackage(at: finalURL)
            let finalAttestation = try DeviceSyncLocalPackageAttestation(
                document: final,
                updatedAt: attestation.updatedAt
            )
            guard finalAttestation == attestation else { return record }
            try await library.confirmPublishPackage(record.workID, attestation)
            return DeviceSyncLocalLibraryRecord(
                workID: record.workID,
                expectedDocumentID: record.expectedDocumentID,
                state: .publishPending,
                package: attestation,
                acknowledgedRemote: nil,
                pendingRemote: nil
            )
        } catch {
            return record
        }
    }

    private func verifyLocalLibraryRecord(
        _ record: DeviceSyncLocalLibraryRecord,
        library: DeviceSyncLibraryRuntime,
        now: Date
    ) async -> StartupVerifiedLocalLibraryItem {
        let canResumeRemoteOpen = if record.state == .remoteOpenPending {
            await library.canResumeRemoteOpenOffline(record.workID)
        } else {
            false
        }
        let hasPublishAuthority = if record.state == .publishPending {
            await library.hasLocalPublishAuthority(record.workID, record.expectedDocumentID)
        } else {
            false
        }
        guard record.package != nil else {
            return StartupVerifiedLocalLibraryItem(
                record: record,
                attestation: nil,
                row: StartupLibraryWork(
                    reference: .cloudWork(record.workID.rawValue),
                    // App registryはaccount-independent。remote projectionをここから
                    // 表示するとaccount切替後に旧作品名を漏らすためgenericにする。
                    title: "ダウンロードを再開する作品",
                    updatedAt: record.pendingRemote?.headClientCreatedAt,
                    availability: record.state == .remoteOpenPending && canResumeRemoteOpen
                        ? .remotePending
                        : record.state == .remoteOpenPending ? .remoteOnly : .unavailable,
                    isTitleTruncated: record.pendingRemote?.isTitleTruncated ?? false
                )
            )
        }
        let verified = await localLibraryPackageTitle(
            workID: record.workID,
            library: library,
            now: record.package?.updatedAt ?? now
        )
        guard let attestation = verified.attestation,
              attestation.documentID == record.expectedDocumentID else {
            return StartupVerifiedLocalLibraryItem(
                record: record,
                attestation: nil,
                row: StartupLibraryWork(
                    reference: .cloudWork(record.workID.rawValue),
                    title: record.package?.titleProjection ?? "確認が必要な作品",
                    updatedAt: record.package?.updatedAt,
                    availability: .unavailable,
                    isTitleTruncated: record.package.map {
                        $0.fullTitleUTF8ByteCount > $0.titleProjection.utf8.count
                    } ?? false
                )
            )
        }

        let journalNeedsReview: Bool
        do {
            journalNeedsReview = try await library.localWorkNeedsReview(
                record.workID,
                record.expectedDocumentID
            )
        } catch {
            return StartupVerifiedLocalLibraryItem(
                record: record,
                attestation: attestation,
                row: StartupLibraryWork(
                    reference: .cloudWork(record.workID.rawValue),
                    title: attestation.titleProjection,
                    updatedAt: attestation.updatedAt,
                    availability: .unavailable,
                    isTitleTruncated: attestation.fullTitleUTF8ByteCount
                        > attestation.titleProjection.utf8.count
                )
            )
        }

        let availability: StartupLibraryWorkAvailability
        if journalNeedsReview {
            availability = .needsReview
        } else if record.state == .remoteOpenPending,
                  let pendingRemote = record.pendingRemote,
                  attestation.matches(pendingRemote),
                  await library.hasCompletedRemoteOpenLocally(pendingRemote) {
            // Domain bind後→App registry acknowledgement前のkill窓。remote catalogが
            // offlineで空でも、exact package・pending projection・outbox-free journal
            // の3点が一致するときだけ耐久な同期済み状態へ昇格する。
            do {
                try await library.markSynced(record.workID, pendingRemote)
                availability = .cachedRemote
            } catch {
                availability = .unavailable
            }
        } else {
            availability = switch record.state {
            case .synced where record.acknowledgedRemote.map(attestation.matches) == true:
                .cachedRemote
            case .needsReview:
                .needsReview
            case .publishPending:
                hasPublishAuthority ? .localPending : .localOnly
            case .synced:
                .localPending
            case .remoteOpenPending:
                canResumeRemoteOpen ? .remotePending : .unavailable
            case .reservedForPublish:
                .unavailable
            }
        }
        return StartupVerifiedLocalLibraryItem(
            record: record,
            attestation: attestation,
            row: StartupLibraryWork(
                reference: .cloudWork(record.workID.rawValue),
                title: attestation.titleProjection,
                updatedAt: attestation.updatedAt,
                availability: availability,
                isTitleTruncated: attestation.fullTitleUTF8ByteCount > attestation.titleProjection.utf8.count
            )
        )
    }

    private func localLibraryPackageTitle(
        workID: SyncWorkID,
        library: DeviceSyncLibraryRuntime,
        now: Date
    ) async -> (attestation: DeviceSyncLocalPackageAttestation?, document: NovelDocument?) {
        do {
            try await library.validateInstalledPackage(workID)
            let url = try await library.packageURL(workID)
            guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                return (nil, nil)
            }
            let loaded = try await portableRepository.validatePortablePackage(at: url)
            let attestation = try DeviceSyncLocalPackageAttestation(document: loaded, updatedAt: now)
            return (attestation, loaded)
        } catch {
            return (nil, nil)
        }
    }

    private func mergeStartupLibrary(
        local: StartupVerifiedLocalLibrarySnapshot,
        remote: DeviceSyncRemoteLibrarySnapshot,
        resumableWorkIDs: [SyncWorkID],
        library: DeviceSyncLibraryRuntime
    ) async -> [StartupLibraryWork] {
        var rows = Dictionary(uniqueKeysWithValues: local.items.map { ($0.key, $0.value.row) })
        var exactEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]

        if remote.connection == .accountRequired || remote.connection == .differentAccount {
            for (workID, localItem) in local.items
                where localItem.record?.state == .remoteOpenPending
                && localItem.attestation == nil {
                // Account-independent App registryだけに残った未download intentは、
                // account identityを再確認できるまで存在自体を棚へ出さない。
                rows.removeValue(forKey: workID)
            }
        }

        for remoteItem in remote.entries {
            let entry = remoteItem.work
            exactEntries[entry.workID] = entry
            if let localItem = local.items[entry.workID],
               let attestation = localItem.attestation {
                let availability: StartupLibraryWorkAvailability
                if localItem.row.availability == .needsReview {
                    availability = .needsReview
                } else if attestation.matches(entry),
                          remoteItem.availability == .locallyBound,
                          await library.hasCompletedRemoteOpenLocally(entry) {
                    // Covers both remote bootstrap→registry mark kill and new-work
                    // publish→registry mark kill. The checkmark appears only after
                    // Domain exact journal truth and App registry durability agree.
                    do {
                        try await library.markSynced(entry.workID, entry)
                        availability = .cachedRemote
                    } catch {
                        availability = .unavailable
                    }
                } else if localItem.record?.state == .remoteOpenPending {
                    // Domainのimmutable pending revisionを先に完了し、moving headへは
                    // 通常WorkSyncで追随する。ここでcurrent catalogへ偽装しない。
                    availability = localItem.row.availability
                } else if entry.headRevisionID == nil {
                    availability = localItem.record?.state == .needsReview ? .needsReview : .localPending
                } else if attestation.matches(entry) {
                    let exactAck = localItem.record?.acknowledgedRemote == entry
                    availability = remoteItem.availability == .locallyBound && exactAck
                        ? .cachedRemote
                        : localItem.record?.state == .needsReview ? .needsReview : .localPending
                } else {
                    availability = localItem.record?.state == .publishPending
                        ? .localPending
                        : .needsReview
                }
                rows[entry.workID] = StartupLibraryWork(
                    reference: .cloudWork(entry.workID.rawValue),
                    title: attestation.titleProjection,
                    updatedAt: attestation.updatedAt,
                    availability: availability,
                    isTitleTruncated: attestation.fullTitleUTF8ByteCount > attestation.titleProjection.utf8.count
                )
            } else if rows[entry.workID]?.availability != .unavailable {
                // Account identityを証明できないsnapshotに含まれたremote-only行は
                // titleを一般化するだけでなく棚から隔離する。端末内packageまたは
                // same-accountのdurable resume identityがある行は別経路で残る。
                // D-071 Note catalogはnil-headでもWorkIDの存在がdownload条件である。
                guard remote.connection != .accountRequired,
                      remote.connection != .differentAccount else { continue }
                let canResume: Bool = if remoteItem.availability == .remoteDownloadPending {
                    await library.canResumeRemoteOpenOffline(entry.workID)
                } else {
                    false
                }
                rows[entry.workID] = StartupLibraryWork(
                    reference: .cloudWork(entry.workID.rawValue),
                    title: entry.title,
                    updatedAt: entry.headClientCreatedAt,
                    availability: canResume ? .remotePending : .remoteOnly,
                    isTitleTruncated: entry.isTitleTruncated
                )
            }
        }

        if remote.connection == .available {
            let listedWorkIDs = Set(remote.entries.map(\.work.workID))
            for (workID, localItem) in local.items
                where localItem.row.availability == .cachedRemote
                && !listedWorkIDs.contains(workID) {
                // 接続中のcurrent catalogに作品が無いのに、過去のreceiptだけで
                // 「同期済み」とは表示しない。hard delete／malformed control／
                // account-side omissionを区別できるまではlocal copyを保持してreviewへ。
                rows[workID] = StartupLibraryWork(
                    reference: localItem.row.reference,
                    title: localItem.row.title,
                    updatedAt: localItem.row.updatedAt,
                    availability: .cloudUnavailable,
                    isTitleTruncated: localItem.row.isTitleTruncated
                )
            }
        }
        startupRemoteLibraryEntries = exactEntries
        return Self.addOfflineResumableRows(resumableWorkIDs, to: Array(rows.values))
    }

    /// Verified local registryの`publishPending`とcanonical local bindingの
    /// 両方が揃うsame-account workだけを自動再送する。WorkControlはheadが
    /// nilの間catalogへ出ないため、remote rowの存在を再送条件にしない。
    private func retryAccountScopedPendingPublications(
        local: StartupVerifiedLocalLibrarySnapshot,
        remote: DeviceSyncRemoteLibrarySnapshot,
        library: DeviceSyncLibraryRuntime
    ) async -> Bool {
        guard remote.connection == .available,
              let portableRepository = repository as? PortableDocumentPackageRepository else {
            return false
        }
        var didPublish = false
        for localItem in local.items.values {
            guard localItem.row.availability == .localPending,
                  localItem.record?.state == .publishPending,
                  let record = localItem.record,
                  let expected = localItem.attestation,
                  await library.hasLocalPublishAuthority(
                      record.workID,
                      record.expectedDocumentID
                  ) else { continue }
            do {
                try await library.validateInstalledPackage(record.workID)
                let url = try await library.packageURL(record.workID)
                let document = try await portableRepository.validatePortablePackage(at: url)
                let readback = try DeviceSyncLocalPackageAttestation(
                    document: document,
                    updatedAt: expected.updatedAt
                )
                guard readback == expected,
                      document.id == record.expectedDocumentID else { continue }
                let isActiveDocument = startupState.isReady
                    && documentURL.standardizedFileURL == url.standardizedFileURL
                if isActiveDocument {
                    try await library.publishNewWork(record.workID, document, url)
                } else {
                    try await library.resumeInitialWorkPublication(record.workID, document, url)
                }
                didPublish = true
            } catch {
                continue
            }
        }
        return didPublish
    }

    /// Chooserを開いていない間も、remote signal／foreground／wakeを契機に
    /// account-scoped pending creationだけを再送する。active document/sessionへ
    /// remote内容を注入せず、package readbackとWorkIDだけで処理する。
    func retryAccountScopedPendingPublicationsInBackground() async {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return }
        if let pendingLibraryRetryTask {
            await pendingLibraryRetryTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let local = try await loadVerifiedLocalLibrary(
                    using: library,
                    now: runtime.now()
                )
                let remote = try await library.loadRemoteLibrary()
                mayAttemptInitialCloudPublish = remote.connection == .available
                    || remote.connection == .offline
                lastStartupLibraryConnection = Self.startupConnection(remote.connection)
                _ = await retryAccountScopedPendingPublications(
                    local: local,
                    remote: remote,
                    library: library
                )
            } catch {
                mayAttemptInitialCloudPublish = false
            }
        }
        pendingLibraryRetryTask = task
        await task.value
        pendingLibraryRetryTask = nil
    }

    private static func addOfflineResumableRows(
        _ workIDs: [SyncWorkID],
        to existingRows: [StartupLibraryWork]
    ) -> [StartupLibraryWork] {
        var rows = Dictionary(uniqueKeysWithValues: existingRows.map { row in
            (row.reference, row)
        })
        for workID in workIDs {
            let reference = StartupLibraryWorkReference.cloudWork(workID.rawValue)
            guard rows[reference] == nil else { continue }
            rows[reference] = StartupLibraryWork(
                reference: reference,
                // Domain intentionally exposes identity only. A title is not carried
                // across an unverified account boundary.
                title: "このMacへの保存を再開する作品",
                updatedAt: nil,
                availability: .remotePending
            )
        }
        return Array(rows.values)
    }

    private static func startupConnection(
        _ connection: DeviceSyncLibraryConnection
    ) -> StartupLibraryConnection {
        switch connection {
        case .available:
            .available
        case .offline:
            .offline
        case .accountRequired:
            .accountRequired
        case .differentAccount:
            .differentAccount
        }
    }

    private static func startupLibrarySort(
        _ lhs: StartupLibraryWork,
        _ rhs: StartupLibraryWork
    ) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (left?, right?) where left != right:
            left > right
        case (nil, _?):
            false
        case (_?, nil):
            true
        default:
            lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    /// Recovery画面の「再試行」。同じ原本URLまたは同じ新規保存先を再利用する。
    func retryStartup() async {
        guard !deviceSyncStartupFailedSafely, !isTerminationPending else { return }
        let recoverySession = documentSessionToken
        await documentOperationGate.perform {
            await retryStartupSerially()
        }
        if startupState.isReady, documentSessionToken != recoverySession {
            // chooserから失敗した作品を再試行した場合も、EditorPaneの生成に依存せず
            // local journalを確認し終えるまで全作品変更をgateする(D-061 / D-062)。
            await prepareActiveDeviceSyncLocally()
        }
    }

    private func retryStartupSerially() async {
        guard case let .recovery(context) = startupState else { return }
        startupState = .loading

        switch context.reason {
        case .cannotOpenDocument, .protectedLocationInDebugBuild:
            guard let url = context.documentURL else {
                startupState = .recovery(context)
                return
            }
            await loadStartupDocument(at: url, source: context.source)
        case .cannotCreateDocument:
            await createInitialDocumentForStartup(at: context.documentURL)
        case .deviceSyncSafetyUnavailable:
            startupState = .recovery(context)
        }
    }

    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        pendingBootstrapOpenURL = nil
        startupState = .recovery(
            StartupRecoveryContext(
                reason: .deviceSyncSafetyUnavailable,
                source: .initialDocument,
                documentURL: nil
            )
        )
    }

    /// Finder / Open Withから渡された作品を、現在作品を守る通常の切替経路で開く。
    @discardableResult
    func openExternalDocument(at url: URL) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        let success = if deviceSyncRuntime?.library != nil {
            await importExternalDocument(at: url, expectedSession: documentSessionToken)
        } else {
            await openDocument(at: url, expectedSession: nil, startupSource: .finder)
        }
        if !success {
            externalDocumentOpenErrorMessage = if deviceSyncRuntime?.library != nil {
                "作品を取り込めませんでした。原本と表示中の作品は変更していません。形式、空き容量、アクセス権限を確認してください。"
            } else {
                "作品を開けませんでした。原稿は切り替えていません。ファイルとアクセス権限を確認してください。"
            }
        }
        return success
    }

    /// D-063の外部packageはopen-in-placeしない。validated package transportが
    /// private stagingへinstallする実装境界（後段でrepository能力を必須化）。
    @discardableResult
    func importExternalDocument(
        at sourceURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        guard let portableRepository = repository as? PortableDocumentPackageRepository,
              deviceSyncRuntime?.library != nil,
              permitsCloudLibraryMutation,
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        let source = sourceURL.standardizedFileURL
        let importedDocument: NovelDocument
        do {
            importedDocument = try await portableRepository.validatePortablePackage(at: source)
        } catch {
            return false
        }
        let publication = await performForCurrentDocument(
            expectedSession: expectedSession,
            ifStale: PendingPrivateLibraryPublication?.none
        ) {
            await createPrivateLibraryWorkSerially(
                importedDocument,
                portableSourceURL: source,
                portableRepository: portableRepository
            )
        }
        if let publication {
            // Legacy visible package remains untouched. Its preference is retired only
            // after private registry+package durability has succeeded.
            userDefaults.removeObject(forKey: Self.recentDocumentPathKey)
            schedulePrivateLibraryPublish(publication)
            await prepareActiveDeviceSyncLocally()
        }
        return publication != nil
    }

    /// 起動画面に表示した前回作品を、その画面を表示したsessionにだけ適用する。
    /// recent URLは表示しただけでは読み込まず、ここで初めてRepositoryへ渡す(D-062)。
    @discardableResult
    func openRecentDocument(expectedSession: DocumentSessionToken) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              let recentDocument = context.recentDocument else { return false }
        return await openDocument(
            at: recentDocument.url,
            expectedSession: expectedSession,
            startupSource: .recentDocument
        )
    }

    /// 起動画面で選んだ作品を、表示時のexact referenceに従って開く。
    /// local pathはViewへ表示せず、cloud workはworkIDだけを選択identityにする。
    @discardableResult
    func openStartupLibraryWork(
        _ reference: StartupLibraryWorkReference,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              context.works.contains(where: { $0.reference == reference }),
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        switch reference {
        case let .recentDocument(url):
            return await openDocument(
                at: url,
                expectedSession: expectedSession,
                startupSource: .recentDocument
            )
        case let .cloudWork(rawWorkID):
            guard let selected = context.works.first(where: { $0.reference == reference }) else {
                return false
            }
            let workID = SyncWorkID(rawValue: rawWorkID)
            switch selected.availability {
            case .cachedRemote, .localPending, .localOnly, .needsReview:
                return await openVerifiedLocalLibraryWork(
                    workID,
                    expectedRow: selected,
                    expectedSession: expectedSession
                )
            case .remoteOnly where context.connection == .available:
                guard let entry = startupRemoteLibraryEntries[workID] else { return false }
                return await downloadAndOpenLibraryWork(
                    entry,
                    expectedRow: selected,
                    expectedSession: expectedSession
                )
            case .remotePending:
                return await resumeAndOpenPendingLibraryWork(
                    workID,
                    expectedRow: selected,
                    expectedSession: expectedSession
                )
            case .remoteOnly, .cloudUnavailable, .unavailable:
                return false
            }
        }
    }

    private func openVerifiedLocalLibraryWork(
        _ workID: SyncWorkID,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard let library = deviceSyncRuntime?.library else { return false }
        let opened = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  case let .documentSelection(context) = startupState,
                  context.works.contains(expectedRow) else { return false }
            do {
                let inventory = try await library.loadLocalInventory()
                guard let record = inventory.records.first(where: { $0.workID == workID }),
                      let recordedPackage = record.package else { return false }
                try await library.validateInstalledPackage(workID)
                let url = try await library.packageURL(workID)
                guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                    return false
                }
                let loaded = try await portableRepository.validatePortablePackage(at: url)
                try await library.validateInstalledPackage(workID)
                let attestation = try DeviceSyncLocalPackageAttestation(
                    document: loaded,
                    updatedAt: recordedPackage.updatedAt
                )
                guard attestation.documentID == record.expectedDocumentID else { return false }
                switch expectedRow.availability {
                case .cachedRemote:
                    guard record.state == .synced,
                          record.acknowledgedRemote.map(attestation.matches) == true else {
                        return false
                    }
                case .localPending:
                    guard record.state == .publishPending || record.state == .synced else {
                        return false
                    }
                case .localOnly:
                    guard record.state == .publishPending,
                          await library.hasLocalPublishAuthority(
                              workID,
                              record.expectedDocumentID
                          ) == false else { return false }
                case .needsReview:
                    // The work journal can discover a review before the local
                    // library registry is promoted from `publishPending` to
                    // `needsReview` (for example after a restart during a
                    // first publish). The package has already passed local
                    // readback, so it is safe to open it; the active work
                    // boundary will keep the unresolved review visible and
                    // control editing.
                    guard record.state != .reservedForPublish else {
                        return false
                    }
                case .remoteOnly, .remotePending, .cloudUnavailable, .unavailable:
                    return false
                }
                let loadedAttachments = try await loadAttachmentsThrowing(for: url)
                installDocument(loaded, at: url, attachments: loadedAttachments)
                return startupState.isReady
            } catch {
                return false
            }
        }
        if opened {
            await prepareActiveDeviceSyncLocally()
        } else {
            scheduleStartupLibraryRemoteRefreshIfNeeded()
        }
        return opened
    }

    private func downloadAndOpenLibraryWork(
        _ expectedEntry: SyncWorkLibraryEntry,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        await materializeAndOpenLibraryWork(
            workID: expectedEntry.workID,
            expectedCatalogEntry: expectedEntry,
            expectedRow: expectedRow,
            expectedSession: expectedSession
        )
    }

    private func resumeAndOpenPendingLibraryWork(
        _ workID: SyncWorkID,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        await materializeAndOpenLibraryWork(
            workID: workID,
            expectedCatalogEntry: nil,
            expectedRow: expectedRow,
            expectedSession: expectedSession
        )
    }

    private func materializeAndOpenLibraryWork(
        workID: SyncWorkID,
        expectedCatalogEntry: SyncWorkLibraryEntry?,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return false }
        let opened = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  case let .documentSelection(context) = startupState,
                  context.works.contains(expectedRow) else {
                return false
            }
            if let expectedCatalogEntry {
                guard context.connection == .available,
                      startupRemoteLibraryEntries[workID] == expectedCatalogEntry else {
                    return false
                }
            }

            var stagingURL: URL?
            do {
                guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                    return false
                }
                let inventory = try await library.loadLocalInventory()
                let pendingRecord = inventory.records.first {
                    $0.workID == workID && $0.state == .remoteOpenPending
                }
                let prepared: DeviceSyncPreparedLibraryWork
                if let pendingRecord, let pendingEntry = pendingRecord.pendingRemote {
                    // Once Domain has staged A, never replace it with moving head B.
                    // A is installed/bound first; ordinary WorkSync then follows B.
                    prepared = try await library.resumeRemoteOpen(workID)
                    guard prepared.entry == pendingEntry else { return false }
                } else if let expectedCatalogEntry {
                    // Domain first persists the account-scoped exact intent and stages the
                    // immutable revision. App registry is written only after that succeeds,
                    // avoiding an account-independent A intent that cannot follow catalog B.
                    prepared = try await library.prepareRemoteOpen(expectedCatalogEntry)
                    guard prepared.entry == expectedCatalogEntry else { return false }
                    try await library.beginRemoteOpen(prepared.entry)
                } else {
                    // Domain pending may outlive a process killed before App registry write.
                    prepared = try await library.resumeRemoteOpen(workID)
                    try await library.beginRemoteOpen(prepared.entry)
                }
                guard prepared.entry.workID == workID,
                      try prepared.packageSnapshot == WorkSnapshot(document: prepared.document) else {
                    return false
                }

                let finalURL = try await library.packageURL(workID)
                let finalDocument: NovelDocument
                if await (try? library.validateInstalledPackage(workID)) != nil {
                    // Crash-resume never replaces an existing final package. It must be the
                    // immutable prepared revision or the work is quarantined.
                    let existing = try await portableRepository.validatePortablePackage(at: finalURL)
                    guard try WorkSnapshot(document: existing) == prepared.packageSnapshot else {
                        let existingAttestation = try DeviceSyncLocalPackageAttestation(
                            document: existing,
                            updatedAt: runtime.now()
                        )
                        try await library.quarantineInstalledPackage(
                            workID,
                            existingAttestation
                        )
                        return false
                    }
                    finalDocument = existing
                } else {
                    let staging = try await library.stagingPackageURL(workID)
                    stagingURL = staging
                    try await repository.save(prepared.document, to: staging)
                    try await library.validateStagingPackage(staging, workID)
                    let stagedReadback = try await portableRepository.validatePortablePackage(at: staging)
                    guard try WorkSnapshot(document: stagedReadback) == prepared.packageSnapshot else {
                        return false
                    }
                    let installed = try await library.installStagingPackage(
                        staging,
                        workID
                    )
                    stagingURL = nil
                    guard installed == finalURL else { return false }
                    try await library.validateInstalledPackage(workID)
                    finalDocument = try await portableRepository.validatePortablePackage(at: finalURL)
                    guard try WorkSnapshot(document: finalDocument) == prepared.packageSnapshot else {
                        return false
                    }
                }

                let attestation = try DeviceSyncLocalPackageAttestation(
                    document: finalDocument,
                    updatedAt: runtime.now()
                )
                try await library.attestRemotePackage(
                    workID,
                    attestation,
                    prepared.entry
                )
                try await prepared.bind(prepared.packageSnapshot)
                try await library.markSynced(workID, prepared.entry)
                let loadedAttachments = try await loadAttachmentsThrowing(for: finalURL)
                installDocument(finalDocument, at: finalURL, attachments: loadedAttachments)
                return startupState.isReady
            } catch {
                if let stagingURL {
                    try? await library.discardStagingPackage(stagingURL, workID)
                }
                return false
            }
        }
        if opened {
            await prepareActiveDeviceSyncLocally()
        } else {
            scheduleStartupLibraryRemoteRefreshIfNeeded()
        }
        return opened
    }

    private func loadStartupDocument(at url: URL, source: StartupDocumentSource) async {
        guard !deviceSyncStartupFailedSafely else { return }
        let targetURL = url.standardizedFileURL
        do {
            let loadedDocument = try await repository.load(from: targetURL)
            let loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
            installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        } catch {
            print("[FUMINIWA] 起動作品を開けませんでした(\(Self.errorCategory(error)))")
            startupState = .recovery(
                StartupRecoveryContext(
                    reason: .cannotOpenDocument,
                    source: source,
                    documentURL: targetURL
                )
            )
        }
    }

    private func createInitialDocumentForStartup(at preferredURL: URL? = nil) async {
        guard !deviceSyncStartupFailedSafely else { return }
        let newDocument = NovelDocument.newDocument()
        let newURL = preferredURL
            ?? Self.availableSaveURL(
                forTitle: newDocument.title,
                fileManager: fileManager,
                directoryName: defaultDocumentDirectoryName
            )

        do {
            try await repository.save(newDocument, to: newURL)
            let newAttachments = try await loadAttachmentsThrowing(for: newURL)
            installDocument(newDocument, at: newURL, attachments: newAttachments)
        } catch {
            print("[FUMINIWA] 起動時の新規作品を保存できませんでした(\(Self.errorCategory(error)))")
            startupState = .recovery(
                StartupRecoveryContext(
                    reason: .cannotCreateDocument,
                    source: .initialDocument,
                    documentURL: newURL
                )
            )
        }
    }

    // MARK: - 作品ライフサイクル

    private func performForCurrentDocument<T>(
        expectedSession: DocumentSessionToken? = nil,
        ifStale staleValue: T,
        operation: @MainActor () async -> T
    ) async -> T {
        guard !isTerminationPending else { return staleValue }
        let originSession = expectedSession ?? documentSessionToken
        return await documentOperationGate.perform {
            guard documentSessionToken == originSession else { return staleValue }
            return await operation()
        }
    }

    /// 確認ダイアログなど、`await`を持たないUI操作を元の作品だけへ適用する。
    /// Save Asを含む作品世代の変更後や終了処理開始後は、IDが同じでも拒否する。
    private func permitsMutation(expectedSession: DocumentSessionToken?) -> Bool {
        guard !isTerminationPending, !isDocumentTransitionInProgress else { return false }
        guard let expectedSession else { return true }
        return documentSessionToken == expectedSession
    }

    /// 表示中Editorが確定済み本文をモデルへ同期するための判定。
    ///
    /// 終了要求後は新しいUI操作を止める一方、既に表示中のIME marked textは
    /// 最終保存へ含める必要がある。固定sessionとの一致だけを確認し、終了処理中の
    /// `prepareForDocumentTransition()`から届く最後のcallbackは受け入れる。
    private func permitsEditorSynchronization(expectedSession: DocumentSessionToken?) -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        guard let expectedSession else { return !isTerminationPending }
        return documentSessionToken == expectedSession
    }

    var permitsDocumentInteraction: Bool {
        !deviceSyncStartupFailedSafely &&
            startupState.isReady &&
            (!usesWholeWorkSyncRuntime || usesNoteSyncRuntime || !deviceSyncLocalRecoveryPending) &&
            (!isDocumentTransitionInProgress || permitsDeviceSyncSelectionMutationAfterFlush)
    }

    var permitsDocumentChoice: Bool {
        !deviceSyncStartupFailedSafely &&
            startupState.permitsDocumentChoice &&
            !isStartupLibraryOperationInProgress &&
            !isDocumentTransitionInProgress &&
            !isTerminationPending
    }

    var permitsReturnToCloudLibrary: Bool {
        deviceSyncRuntime?.library != nil && permitsDocumentInteraction
    }

    /// Workbenchの作品を端末へ確定してから、同じwindowでcloud shelfへ戻る。
    /// active package URLはUIへ渡さず、session generationを進めて旧View actionを無効化する。
    @discardableResult
    func returnToStartupLibrary(
        expectedSession: DocumentSessionToken? = nil,
        localFirst: Bool = false
    ) async -> Bool {
        guard deviceSyncRuntime?.library != nil else { return false }
        let returned = await performForCurrentDocument(
            expectedSession: expectedSession,
            ifStale: false
        ) {
            guard startupState.isReady, beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else {
                return false
            }

            advanceDocumentSession(document: document, url: documentURL)
            deviceSyncSelectionDidChange()
            startupLibraryRefreshGeneration &+= 1
            startupRemoteLibraryEntries = [:]
            permitsCloudLibraryMutation = false
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .offline,
                    isLoading: true
                )
            )
            return true
        }
        if returned {
            _ = await refreshLocalStartupLibrary()
            if localFirst {
                scheduleStartupLibraryRemoteRefreshIfNeeded()
            } else {
                await refreshStartupLibrary()
            }
        }
        return returned
    }

    /// provider待機でdocument operation gateを保持せず、開始／再検査時だけ現在作品を読むための条件。
    /// 終了要求後は`permitsDocumentInteraction`がtrueでも新しい長時間処理を開始しない。
    var permitsLongRunningDocumentOperation: Bool {
        !deviceSyncStartupFailedSafely &&
            startupState.isReady &&
            !isDocumentTransitionInProgress &&
            !isTerminationPending
    }

    /// TextField等のfirst responderとEditorKit本文を同じ同期区間で確定し、
    /// 次の保存・installが終わるまで旧Workbenchからの変更を閉じる。
    func beginDocumentTransition() -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        if let keyWindow = NSApp.keyWindow, !keyWindow.makeFirstResponder(nil) {
            return false
        }
        guard editorCommandSession.prepareForDocumentTransition() else { return false }
        isDocumentTransitionInProgress = true
        return true
    }

    func endDocumentTransition() {
        isDocumentTransitionInProgress = false
        editorCommandSession.resumeAfterDocumentTransition()
    }

    /// 現在の作品を失わず、指定 URL の作品へ切り替える。
    ///
    /// 読み込み結果は一時値に保持し、本文と資料一覧の両方を取得できた後で現在作品の
    /// 保留中保存を完了させる。保存または読み込みに失敗した場合は、現在の状態を
    /// 一切置き換えない。
    @discardableResult
    func openDocument(
        at url: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await openDocument(
            at: url,
            expectedSession: expectedSession,
            startupSource: .chosenDocument
        )
    }

    private func openDocument(
        at url: URL,
        expectedSession: DocumentSessionToken?,
        startupSource: StartupDocumentSource
    ) async -> Bool {
        guard !deviceSyncStartupFailedSafely, !isTerminationPending else { return false }
        let preparesSelectedStartupDocument = switch startupState {
        case .documentSelection, .recovery:
            true
        case .loading, .ready:
            false
        }
        let opened = await documentOperationGate.perform {
            if let expectedSession, documentSessionToken != expectedSession {
                return false
            }
            return await openDocumentSerially(at: url, startupSource: startupSource)
        }
        if opened, preparesSelectedStartupDocument {
            // 通常起動のchooserはscene起動時のpreflight後に作品をinstallする。
            // Workbenchや保存セクションの表示有無へ依存せず、選択した作品自身を
            // activation直後にlocal journal復旧へ接続する(D-061 / D-062)。
            await prepareActiveDeviceSyncLocally()
        }
        return opened
    }

    /// Opening a locally verified package completes the foreground transition
    /// only after local journal recovery. The preparation lane schedules remote
    /// publication separately, so this never waits for CloudKit synchronization.
    private func prepareActiveDeviceSyncLocally() async {
        guard startupState.isReady else { return }
        if usesWholeWorkSyncRuntime, let identity = currentWorkSyncPreparationIdentity {
            await prepareWholeWorkSync(for: identity)
        } else if let lookup = currentDeviceSyncLookupIdentity {
            await prepareDeviceSync(for: lookup)
        }
    }

    func scheduleActiveDeviceSyncPreparation() {
        Task { @MainActor [weak self] in
            await self?.refreshOrPrepareSelectedEpisodeDeviceSync()
        }
    }

    private func openDocumentSerially(
        at url: URL,
        startupSource: StartupDocumentSource
    ) async -> Bool {
        let targetURL = url.standardizedFileURL
        let hadReadyDocument = startupState.isReady
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        guard !hadReadyDocument || targetURL != documentURL.standardizedFileURL else {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            return await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: false,
                waitForRemote: false
            )
        }
        if !hadReadyDocument {
            startupState = .loading
        }

        let loadedDocument: NovelDocument
        let loadedAttachments: [Attachment]
        do {
            loadedDocument = try await repository.load(from: targetURL)
            loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
        } catch {
            print("[FUMINIWA] 作品の読み込みに失敗しました(\(Self.errorCategory(error)))")
            if !hadReadyDocument {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .cannotOpenDocument,
                        source: startupSource,
                        documentURL: targetURL
                    )
                )
            }
            return false
        }

        // 読み込み待ちの間に現在作品が編集されても、ここで全入力を確定・停止し、
        // 最新revisionを保存してから切り替える。
        if hadReadyDocument {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else { return false }
        }

        installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        return true
    }

    /// 新規作品を既定保存先へ作成し、保存成功後にだけ現在作品として採用する。
    @discardableResult
    func createNewDocument(expectedSession: DocumentSessionToken? = nil) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        if deviceSyncRuntime?.library != nil {
            guard permitsCloudLibraryMutation,
                  !isStartupLibraryOperationInProgress else { return false }
            isStartupLibraryOperationInProgress = true
            defer { isStartupLibraryOperationInProgress = false }
            let publication = await performForCurrentDocument(
                expectedSession: expectedSession,
                ifStale: PendingPrivateLibraryPublication?.none
            ) {
                await createPrivateLibraryWorkSerially(
                    NovelDocument.newDocument(),
                    portableSourceURL: nil,
                    portableRepository: nil
                )
            }
            if let publication {
                schedulePrivateLibraryPublish(publication)
                scheduleActiveDeviceSyncPreparation()
            }
            return publication != nil
        }
        let preparesSelectedStartupDocument = switch startupState {
        case .documentSelection, .recovery:
            true
        case .loading, .ready:
            false
        }
        let created = await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await createNewDocumentSerially()
        }
        if created, preparesSelectedStartupDocument {
            await prepareActiveDeviceSyncLocally()
        }
        return created
    }

    func createPrivateLibraryWorkSerially(
        _ requestedDocument: NovelDocument,
        portableSourceURL: URL?,
        portableRepository: (any PortableDocumentPackageRepository)?,
        activate: Bool = true
    ) async -> PendingPrivateLibraryPublication? {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              let validatedRepository = repository as? PortableDocumentPackageRepository,
              permitsCloudLibraryMutation else { return nil }
        let hadReadyDocument = startupState.isReady
        let workID = SyncWorkID()
        var stagingURL: URL?
        var didReserve = false
        var didAttestStaging = false
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        do {
            let expectedAttestation = try DeviceSyncLocalPackageAttestation(
                document: requestedDocument,
                updatedAt: runtime.now()
            )
            try await library.reserveForPublish(workID, expectedAttestation)
            didReserve = true
            let staging = try await library.stagingPackageURL(workID)
            stagingURL = staging
            if let portableSourceURL, let portableRepository {
                let finalURL = try await library.packageURL(workID)
                guard !Self.urlsOverlap(portableSourceURL, staging),
                      !Self.urlsOverlap(portableSourceURL, finalURL) else {
                    throw DeviceSyncLocalLibraryError.packageMismatch
                }
                let validated = try await portableRepository.validatePortablePackage(
                    at: portableSourceURL
                )
                guard validated == requestedDocument else {
                    throw DeviceSyncLocalLibraryError.packageMismatch
                }
                try await portableRepository.saveValidatedCopy(
                    requestedDocument,
                    from: portableSourceURL,
                    to: staging
                )
            } else {
                try await repository.save(requestedDocument, to: staging)
            }

            try await library.validateStagingPackage(staging, workID)
            let stagedReadback = try await validatedRepository.validatePortablePackage(at: staging)
            guard stagedReadback == requestedDocument,
                  try WorkSnapshot(document: stagedReadback) == WorkSnapshot(document: requestedDocument) else {
                throw DeviceSyncLocalLibraryError.packageMismatch
            }
            let attestation = try DeviceSyncLocalPackageAttestation(
                document: stagedReadback,
                updatedAt: expectedAttestation.updatedAt
            )
            guard attestation == expectedAttestation else {
                throw DeviceSyncLocalLibraryError.packageMismatch
            }
            try await library.attestPublishStaging(workID, attestation)
            didAttestStaging = true

            let finalURL = try await library.installStagingPackage(staging, workID)
            stagingURL = nil
            try await library.validateInstalledPackage(workID)
            let finalReadback = try await validatedRepository.validatePortablePackage(at: finalURL)
            let finalAttestation = try DeviceSyncLocalPackageAttestation(
                document: finalReadback,
                updatedAt: attestation.updatedAt
            )
            guard finalReadback == requestedDocument,
                  finalAttestation == attestation else {
                throw DeviceSyncLocalLibraryError.packageMismatch
            }
            try await library.confirmPublishPackage(workID, attestation)

            if activate {
                if hadReadyDocument {
                    guard beginDocumentTransition() else { return nil }
                    didBeginTransition = true
                    guard await flushPreparedDeviceSyncBoundarySerially(
                        releaseAuthority: true,
                        waitForRemote: false
                    ) else {
                        return nil
                    }
                }
                let loadedAttachments = try await loadAttachmentsThrowing(for: finalURL)
                isCurrentWorkBoundToCloud = false
                installDocument(finalReadback, at: finalURL, attachments: loadedAttachments)
                guard startupState.isReady else { return nil }
            }
            return PendingPrivateLibraryPublication(
                workID: workID,
                document: finalReadback,
                packageURL: finalURL,
                mayAttemptInitialPublish: mayAttemptInitialCloudPublish
            )
        } catch {
            if let stagingURL, !didAttestStaging {
                try? await library.discardStagingPackage(stagingURL, workID)
            }
            if didReserve, !didAttestStaging {
                try? await library.abortPublishReservation(workID)
            }
            return nil
        }
    }

    /// Package/registryと旧作品の最終保存、新作品activationが完了した後だけ
    /// account-scoped createを試す。通信失敗時はlocalPendingを残し、作品切替を
    /// 巻き戻さない。
    func schedulePrivateLibraryPublish(
        _ publication: PendingPrivateLibraryPublication
    ) {
        guard publication.mayAttemptInitialPublish else { return }
        guard pendingLibraryPublishTasks[publication.workID] == nil else { return }
        let task = Task { [weak self] in
            guard let self, let library = deviceSyncRuntime?.library else { return }
            try? await library.publishNewWork(
                publication.workID,
                publication.document,
                publication.packageURL
            )
            pendingLibraryPublishTasks[publication.workID] = nil
            if startupState.isReady,
               documentURL.standardizedFileURL == publication.packageURL.standardizedFileURL {
                scheduleActiveDeviceSyncPreparation()
            } else if case let .documentSelection(context) = startupState,
                      context.presentation == .cloudLibrary {
                scheduleStartupLibraryRemoteRefreshIfNeeded()
            }
        }
        pendingLibraryPublishTasks[publication.workID] = task
    }

    private static func urlsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.path
        let right = rhs.standardizedFileURL.path
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// Error descriptions may embed full private paths. Console gets only a stable
    /// operation-local category; UI presents a separate path-free message.
    static func errorCategory(_ error: any Error) -> String {
        String(reflecting: type(of: error))
    }

    func portableDocumentRepository() -> (any PortableDocumentPackageRepository)? {
        repository as? PortableDocumentPackageRepository
    }

    private func createNewDocumentSerially() async -> Bool {
        let hadReadyDocument = startupState.isReady
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }
        let previousRecoveryContext: StartupRecoveryContext? = if case let .recovery(context) = startupState {
            context
        } else {
            nil
        }

        if !hadReadyDocument {
            startupState = .loading
        }

        let newDocument = NovelDocument.newDocument()
        let newURL = Self.availableSaveURL(
            forTitle: newDocument.title,
            fileManager: fileManager,
            directoryName: defaultDocumentDirectoryName
        )
        let newAttachments: [Attachment]

        do {
            try await repository.save(newDocument, to: newURL)
            newAttachments = try await loadAttachmentsThrowing(for: newURL)
        } catch {
            print("[FUMINIWA] 新規作品の保存に失敗しました(\(Self.errorCategory(error)))")
            if !hadReadyDocument {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .cannotCreateDocument,
                        source: .initialDocument,
                        documentURL: newURL
                    )
                )
            } else if let previousRecoveryContext {
                startupState = .recovery(previousRecoveryContext)
            }
            return false
        }

        // 新規作品の書き込み中にも現在作品は編集できる。切り替え直前に全入力を
        // 確定・停止し、最新revisionを現在の保存先へ確実に残す。
        if hadReadyDocument {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else { return false }
        }

        installDocument(newDocument, at: newURL, attachments: newAttachments)
        return true
    }

    /// 現在作品を別 URL へ複製し、成功後にだけ保存先を切り替える。
    ///
    /// `DocumentCopyingRepository` が利用できる場合は、モデル外の資料・
    /// スナップショット・未知項目も保存層に引き継がせる。コピー中に生じた編集は
    /// dirty revision として残り、保存先切り替え後に新 URL へ保存される。
    @discardableResult
    func saveDocument(as url: URL, expectedSession: DocumentSessionToken? = nil) async -> Bool {
        await saveDocumentResult(as: url, expectedSession: expectedSession) == .saved
    }

    /// Presenterが非同期完了後の可変状態から失敗理由を推測しないための結果付き経路。
    func saveDocumentResult(
        as url: URL,
        expectedSession: DocumentSessionToken? = nil,
        preAdoptionValidation: (@Sendable (URL) throws -> Void)? = nil
    ) async -> SaveDocumentAsResult {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: .staleSession) {
            await saveDocumentSerially(
                as: url,
                preAdoptionValidation: preAdoptionValidation
            )
        }
    }

    private func saveDocumentSerially(
        as url: URL,
        preAdoptionValidation: (@Sendable (URL) throws -> Void)? = nil
    ) async -> SaveDocumentAsResult {
        guard startupState.isReady else { return .failedBeforeSwitch }
        let destinationURL = url.standardizedFileURL
        let sourceURL = documentURL

        guard destinationURL != sourceURL.standardizedFileURL else {
            return await saveCoordinator.saveNow() ? .saved : .failedBeforeSwitch
        }

        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        guard beginDocumentTransition() else { return .failedBeforeSwitch }
        didBeginTransition = true
        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        ) else {
            return .failedBeforeSwitch
        }
        // Device Sync の旧話authorityはcopy開始前に安全に閉じる。一方、通常の
        // local-only作品では大きなpackage copy中も執筆を止めないため、ここで
        // Editorを一度再開し、保存先を採用する直前にもう一度確定する。
        endDocumentTransition()
        didBeginTransition = false

        do {
            let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                let documentSnapshot = document
                if let copyingRepository = repository as? DocumentCopyingRepository {
                    try await copyingRepository.saveCopy(
                        documentSnapshot,
                        from: sourceURL,
                        to: destinationURL
                    )
                } else {
                    try await repository.save(documentSnapshot, to: destinationURL)
                }
                try preAdoptionValidation?(destinationURL)

                // copy中に増えたlocal-only編集を旧sessionへ確定したうえで、
                // URL・recent・session世代を一つの保存排他区間内で切り替える。
                guard beginDocumentTransition() else { return false }
                didBeginTransition = true
                // URL・recent・session世代の切替までを保存排他区間に含める。
                // コピー中に待機した通常保存が、旧URLへ再開する隙間を作らない。
                documentURL = destinationURL
                rememberDocumentURL(destinationURL)
                advanceDocumentSession(document: document, url: destinationURL)
                deviceSyncSelectionDidChange()
                return true
            }

            switch result {
            case .saveFailedBeforeOperation:
                return .failedBeforeSwitch
            case let .completed(didSwitch, savedAfterOperation):
                guard didSwitch else { return .failedBeforeSwitch }
                return savedAfterOperation ? .saved : .switchedButLatestEditsFailed
            }
        } catch {
            print("[FUMINIWA] 別名保存に失敗しました(\(Self.errorCategory(error)))")
            return .failedBeforeSwitch
        }
    }

    /// 現在のapp-private作業コピーを、利用者が選んだportable `.novelpkg`へ
    /// 複製する。書き出し先を現在作品として採用せず、recent URL、document
    /// session、Device Sync bindingも変更しない。
    func exportDocumentPackage(
        to url: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async throws {
        let exported = await performForCurrentDocument(
            expectedSession: expectedSession,
            ifStale: false
        ) {
            await exportDocumentPackageSerially(to: url)
        }
        guard exported else { throw PackageExportError.staleSession }
    }

    private func exportDocumentPackageSerially(to url: URL) async -> Bool {
        guard startupState.isReady else { return false }
        let destinationURL = url.standardizedFileURL
        let sourceURL = documentURL.standardizedFileURL
        guard !Self.urlsOverlap(destinationURL, sourceURL) else { return false }

        guard beginDocumentTransition() else { return false }
        defer { endDocumentTransition() }

        // native editor / forms → app-private package → Work journalを確定してから
        // その値を複製する。remote処理やactive URLの切替は行わない。
        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: false,
            waitForRemote: false
        ) else {
            return false
        }

        do {
            let documentSnapshot = document
            guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                throw PackageExportError.unavailable
            }
            try await portableRepository.saveValidatedCopy(
                documentSnapshot,
                from: sourceURL,
                to: destinationURL
            )
            let readBack = try await portableRepository.validatePortablePackage(at: destinationURL)
            guard readBack == documentSnapshot else {
                throw PackageExportError.saveFailed
            }
            return true
        } catch {
            print("[FUMINIWA] 作品パッケージの書き出しに失敗しました(\(Self.errorCategory(error)))")
            return false
        }
    }

    // MARK: - 選択中章

    /// Project Sidebar のセクションを選択する。UI2 では画面の主導線として使う。
    func selectProjectSection(_ section: ProjectSection) {
        guard workspaceSelection.section != section else { return }
        guard deviceSyncRuntime == nil || permitsDeviceSyncProjectSectionMutationAfterFlush else { return }
        workspaceSelection = WorkspaceSelection(section: section)
        if section == .worldbuilding {
            ensureWorldNoteSelection()
        }
    }

    /// 選択中の章(存在しなければ `nil`)。
    var selectedChapter: Chapter? {
        guard let selectedChapterID else { return nil }
        return document.chapters.first { $0.id == selectedChapterID }
    }

    /// 選択中の話(存在しなければ `nil`)。
    var selectedEpisode: Episode? {
        guard let selectedEpisodeID else { return nil }
        return selectedChapter?.episodes.first { $0.id == selectedEpisodeID }
    }

    /// 本文右クリックで取得したexact selectionから、AIチャット用promptをコピーする。
    ///
    /// context menu表示後に作品や話が変わっていた場合は、同じ文字列が存在しても
    /// 現在選択へ読み替えない。IME変換中も未確定文字を欠いたpromptを作らない。
    @discardableResult
    func copySelectionAIChatPrompt(
        purpose: AIClipboardPromptPurpose,
        selectedText: String,
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        let episodeStillExists = document.chapters.first(where: { $0.id == chapterID })?
            .episodes.contains(where: { $0.id == episodeID }) == true
        let isCurrentSelection = isCurrentAIClipboardPromptContext(expectedSession) &&
            workspaceSelection.section == .structure &&
            selectedChapterID == chapterID &&
            selectedEpisodeID == episodeID &&
            episodeStillExists
        guard isCurrentSelection else {
            return failAIClipboardPromptCopy(.staleContext)
        }

        switch activeCommittedTextCapture() {
        case .captured:
            return copyAIClipboardPrompt(
                purpose: purpose,
                source: .selection(text: selectedText)
            )
        case .compositionInProgress:
            return failAIClipboardPromptCopy(.compositionInProgress)
        case .notActive:
            return failAIClipboardPromptCopy(.staleContext)
        }
    }

    /// 指定話のタイトルと本文だけを含むAIチャット用promptをコピーする。
    @discardableResult
    func copyEpisodeAIChatPrompt(
        purpose: AIClipboardPromptPurpose,
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard isCurrentAIClipboardPromptContext(expectedSession) else {
            return failAIClipboardPromptCopy(.staleContext)
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
            return failAIClipboardPromptCopy(.staleContext)
        }
        guard let episode = chapter.episodes.first(where: { $0.id == episodeID }) else {
            return failAIClipboardPromptCopy(.staleContext)
        }

        let content: String
        if workspaceSelection.section == .structure,
           selectedChapterID == chapterID,
           selectedEpisodeID == episodeID {
            switch activeCommittedTextCapture() {
            case let .captured(committedText):
                content = committedText
            case .compositionInProgress:
                return failAIClipboardPromptCopy(.compositionInProgress)
            case .notActive:
                content = episode.content
            }
        } else {
            content = episode.content
        }

        return copyAIClipboardPrompt(
            purpose: purpose,
            source: .episode(title: episode.title, content: content)
        )
    }

    /// 指定章のタイトルと、配列順の全話タイトル／本文だけを含むpromptをコピーする。
    @discardableResult
    func copyChapterAIChatPrompt(
        purpose: AIClipboardPromptPurpose,
        chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard isCurrentAIClipboardPromptContext(expectedSession) else {
            return failAIClipboardPromptCopy(.staleContext)
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
            return failAIClipboardPromptCopy(.staleContext)
        }

        var activeEpisodeContent: (id: EpisodeID, text: String)?
        let selectedEpisodeBelongsToChapter = selectedEpisodeID.map { selectedEpisodeID in
            chapter.episodes.contains(where: { $0.id == selectedEpisodeID })
        } ?? false
        let activeEpisodeID = workspaceSelection.section == .structure &&
            selectedChapterID == chapterID && selectedEpisodeBelongsToChapter
            ? selectedEpisodeID
            : nil
        if let activeEpisodeID {
            switch activeCommittedTextCapture() {
            case let .captured(committedText):
                activeEpisodeContent = (activeEpisodeID, committedText)
            case .compositionInProgress:
                return failAIClipboardPromptCopy(.compositionInProgress)
            case .notActive:
                break
            }
        }

        let episodes = chapter.episodes.map { episode in
            AIClipboardPromptEpisode(
                title: episode.title,
                content: activeEpisodeContent?.id == episode.id
                    ? activeEpisodeContent?.text ?? episode.content
                    : episode.content
            )
        }
        return copyAIClipboardPrompt(
            purpose: purpose,
            source: .chapter(title: chapter.title, episodes: episodes)
        )
    }

    func dismissAIClipboardPromptCopyNotice() {
        aiClipboardPromptNoticeDismissTask?.cancel()
        aiClipboardPromptNoticeDismissTask = nil
        aiClipboardPromptCopyNotice = nil
    }

    private func isCurrentAIClipboardPromptContext(_ expectedSession: DocumentSessionToken) -> Bool {
        permitsLongRunningDocumentOperation && documentSessionToken == expectedSession
    }

    @discardableResult
    private func copyAIClipboardPrompt(
        purpose: AIClipboardPromptPurpose,
        source: AIClipboardPromptSource
    ) -> Bool {
        do {
            let prompt = try AIClipboardPromptBuilder.make(purpose: purpose, source: source)
            guard clipboardWriter.writePlainText(prompt.text) else {
                return failAIClipboardPromptCopy(.clipboardWriteFailed)
            }
            presentAIClipboardPromptCopyNotice(.success)
            return true
        } catch let error as AIClipboardPromptError {
            return failAIClipboardPromptCopy(copyFailure(for: error))
        } catch {
            return failAIClipboardPromptCopy(.promptEncodingFailed)
        }
    }

    private func copyFailure(for error: AIClipboardPromptError) -> AIClipboardPromptCopyFailure {
        switch error {
        case .emptyContent:
            .emptyContent
        case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .promptUTF8ByteLimitExceeded:
            .contentTooLarge
        case .encodingFailed:
            .promptEncodingFailed
        }
    }

    @discardableResult
    private func failAIClipboardPromptCopy(_ failure: AIClipboardPromptCopyFailure) -> Bool {
        presentAIClipboardPromptCopyNotice(.failure(failure))
        return false
    }

    private func presentAIClipboardPromptCopyNotice(_ outcome: AIClipboardPromptCopyOutcome) {
        aiClipboardPromptNoticeDismissTask?.cancel()
        let notice = AIClipboardPromptCopyNotice(outcome: outcome)
        aiClipboardPromptCopyNotice = notice
        aiClipboardPromptNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, aiClipboardPromptCopyNotice?.id == notice.id else { return }
            aiClipboardPromptCopyNotice = nil
            aiClipboardPromptNoticeDismissTask = nil
        }
    }

    /// 選択中の登場人物(存在しなければ `nil`)。
    var selectedCharacter: NovelCore.Character? {
        guard let selectedCharacterID else { return nil }
        return document.characters.first { $0.id == selectedCharacterID }
    }

    /// 選択中のプロットカード(存在しなければ `nil`)。
    var selectedPlotCard: PlotCard? {
        guard let selectedPlotCardID else { return nil }
        return document.plotCards.first { $0.id == selectedPlotCardID }
    }

    /// 選択中の伏線(存在しなければ `nil`)。
    var selectedFlag: Flag? {
        guard let selectedFlagID else { return nil }
        return document.flags.first { $0.id == selectedFlagID }
    }

    /// 選択中の世界観ノート(存在しなければ `nil`)。
    var selectedWorldNote: WorldNote? {
        guard let selectedWorldNoteID else { return nil }
        return document.worldNotes.first { $0.id == selectedWorldNoteID }
    }

    // MARK: - 世界観ノート

    /// 世界観ノートを追加し、追加したノートを選択する。
    func addWorldNote() {
        guard permitsDocumentInteraction else { return }
        let note = WorldNote(title: "")
        document.worldNotes.append(note)
        selectedWorldNoteID = note.id
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 世界観ノートを選択する。選択前の本文はdidChangeでモデルへ反映済みとする。
    func selectWorldNote(_ id: WorldNoteID?) {
        guard permitsDocumentInteraction else { return }
        guard id == nil || document.worldNotes.contains(where: { $0.id == id }) else { return }
        guard selectedWorldNoteID != id else { return }
        selectedWorldNoteID = id
        flushSaveImmediately()
    }

    /// 世界観ノートのタイトルを更新する。空タイトルは編集中の値として許可する。
    func updateWorldNoteTitle(_ title: String, for id: WorldNoteID) {
        guard permitsDocumentInteraction else { return }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }),
              document.worldNotes[index].title != title else { return }
        document.worldNotes[index].title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 世界観ノートの本文を更新する。モデル反映は即時、保存だけをデバウンスする。
    func updateWorldNoteContent(
        _ content: String,
        for id: WorldNoteID,
        expectedSession: DocumentSessionToken? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }),
              document.worldNotes[index].content != content else { return }
        document.worldNotes[index].content = content
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 世界観ノートを削除し、隣接ノートへ選択を移す。
    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }) else { return false }
        document.worldNotes.remove(at: index)
        if selectedWorldNoteID == id {
            let fallbackIndex = min(index, max(document.worldNotes.count - 1, 0))
            selectedWorldNoteID = document.worldNotes.indices.contains(fallbackIndex)
                ? document.worldNotes[fallbackIndex].id
                : nil
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 世界観ノートの並び順を更新する。
    func moveWorldNotes(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.worldNotes.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    private func ensureWorldNoteSelection() {
        if let selectedWorldNoteID,
           document.worldNotes.contains(where: { $0.id == selectedWorldNoteID }) {
            return
        }
        selectedWorldNoteID = document.worldNotes.first?.id
    }

    /// 章を選択する。最後に選択していた話、なければ先頭の話も選択する。
    /// 選択が変わるたびに即座に保存する(docs/DESIGN.md 6.4)。
    func selectChapter(_ id: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard id != selectedChapterID else { return }
        guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        setSelection(chapterID: id, episodeID: id.flatMap(preferredEpisodeID(in:)))
        flushSaveImmediately()
    }

    /// プロット画面の章Outline選択を更新する。章を選んだときは執筆側の章選択も揃える。
    func selectPlotOutline(_ selection: PlotOutlineSelection) {
        guard permitsDocumentInteraction else { return }
        guard selection != plotOutlineSelection else { return }
        if case let .chapter(chapterID) = selection, chapterID != selectedChapterID {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        }
        plotOutlineSelection = selection
        if case let .chapter(chapterID) = selection {
            setSelection(chapterID: chapterID, episodeID: preferredEpisodeID(in: chapterID))
            flushSaveImmediately()
        }
    }

    /// 話を選択する。`chapterID` を省略した場合は現在の章を対象にする。
    func selectEpisode(_ id: EpisodeID?, in chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID else { return }
        guard targetChapterID == selectedChapterID && id == selectedEpisodeID ||
            permitsSynchronousDeviceSyncSelectionMutation else { return }
        guard let id else {
            guard document.chapters.first(where: { $0.id == targetChapterID })?.episodes.isEmpty == true else { return }
            setSelection(chapterID: targetChapterID, episodeID: nil)
            flushSaveImmediately()
            return
        }
        guard document.chapters.contains(where: { chapter in
            chapter.id == targetChapterID && chapter.episodes.contains(where: { $0.id == id })
        }) else { return }
        setSelection(chapterID: targetChapterID, episodeID: id)
        flushSaveImmediately()
    }

    // MARK: - 章操作(ロジックは NovelDocument 側のヘルパーに委譲)

    /// 章を末尾に追加し、追加した章を選択状態にする。
    func addChapter() {
        guard permitsDocumentInteraction else { return }
        guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        let title = "第\(document.chapters.count + 1)章"
        let newID = document.addChapter(title: title)
        setSelection(chapterID: newID, episodeID: nil)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 指定章に話を追加し、追加した話を選択する。
    ///
    /// `title` を省略したときは、その章内の通し番号で「第N話」を付ける(UIFIX 2.1)。
    func addEpisode(to chapterID: ChapterID? = nil, title: String? = nil) {
        guard permitsDocumentInteraction else { return }
        guard permitsSynchronousDeviceSyncSelectionMutation else { return }
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID,
              let chapter = document.chapters.first(where: { $0.id == targetChapterID }) else { return }
        let resolvedTitle = title ?? "第\(chapter.episodes.count + 1)話"
        guard let episodeID = document.addEpisode(to: targetChapterID, title: resolvedTitle) else { return }
        setSelection(chapterID: targetChapterID, episodeID: episodeID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 選択中話のタイトルを更新する。
    func updateSelectedEpisodeTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedEpisodeID, let selectedChapterID else { return }
        guard selectedEpisode?.title != title else { return }
        document.updateEpisodeTitle(title, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話のタイトルを更新する。
    func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard permitsDocumentInteraction else { return }
        guard document.episode(episodeID)?.episode.title != title else { return }
        document.updateEpisodeTitle(title, for: episodeID, in: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品タイトルを更新する。空タイトルも編集中は許可し、保存はデバウンスする。
    func updateDocumentTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard document.title != title else { return }
        document.title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品あらすじを更新する。保存形式の詳細はNovelStorageに閉じ込める。
    func updateDocumentSynopsis(_ synopsis: String) {
        guard permitsDocumentInteraction else { return }
        guard document.synopsis != synopsis else { return }
        document.synopsis = synopsis
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話タイトルの編集を確定し、空タイトルを既定値へ戻す。
    func commitEpisodeTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in document.chapters {
            for episode in chapter.episodes {
                let normalizedTitle = normalizedEpisodeTitle(episode.title)
                if episode.title != normalizedTitle {
                    document.updateEpisodeTitle(normalizedTitle, for: episode.id, in: chapter.id)
                    saveCoordinator.markDirty()
                }
            }
        }
        flushSaveImmediately()
    }

    /// 章タイトルを更新する。タイトル編集中は頻繁に呼ばれるため保存はデバウンスする。
    func updateChapterTitle(_ title: String, for id: ChapterID) {
        guard permitsDocumentInteraction else { return }
        guard document.chapters.first(where: { $0.id == id })?.title != title else { return }
        document.updateTitle(title, for: id)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// タイトル編集の確定時に、未保存分を即時保存へ寄せる。
    func commitChapterTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in document.chapters {
            let normalizedTitle = normalizedChapterTitle(chapter.title)
            if chapter.title != normalizedTitle {
                document.updateTitle(normalizedTitle, for: chapter.id)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 章を削除し、隣接章へ選択を移す。最後の1章は削除しない。
    @discardableResult
    func deleteChapter(id: ChapterID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        if selectedChapterID == id {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return false }
        }
        guard document.chapters.count > 1 else { return false }
        guard let originalIndex = document.chapters.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeChapter(id: id) != nil else { return false }

        if selectedChapterID == id {
            let fallbackIndex = min(originalIndex, document.chapters.count - 1)
            let fallbackChapterID = document.chapters.indices.contains(fallbackIndex) ? document.chapters[fallbackIndex].id : nil
            setSelection(chapterID: fallbackChapterID, episodeID: fallbackChapterID.flatMap(preferredEpisodeID(in:)))
        }
        if case let .chapter(focusedID) = plotOutlineSelection, focusedID == id {
            if let selectedChapterID {
                plotOutlineSelection = .chapter(selectedChapterID)
            } else {
                plotOutlineSelection = .unassigned
            }
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 章を並べ替える(`List.onMove` からそのまま呼べる形)。
    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を削除し、同じ章の隣接話へ選択を移す。
    @discardableResult
    func deleteEpisode(
        id episodeID: EpisodeID,
        from chapterID: ChapterID? = nil,
        expectedSession: DocumentSessionToken? = nil
    ) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        if selectedEpisodeID == episodeID {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return false }
        }
        let sourceChapterID = chapterID ?? selectedChapterID
        guard let sourceChapterID,
              let originalIndex = document.episode(episodeID)?.chapterID == sourceChapterID
              ? document.chapters.first(where: { $0.id == sourceChapterID })?.episodes.firstIndex(where: { $0.id == episodeID })
              : nil,
              document.removeEpisode(id: episodeID, from: sourceChapterID) != nil else { return false }

        if selectedEpisodeID == episodeID {
            let remaining = document.chapters.first(where: { $0.id == sourceChapterID })?.episodes ?? []
            let fallbackIndex = min(originalIndex, max(remaining.count - 1, 0))
            let fallbackEpisodeID = remaining.indices.contains(fallbackIndex) ? remaining[fallbackIndex].id : nil
            setSelection(chapterID: sourceChapterID, episodeID: fallbackEpisodeID)
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 章内の話を並べ替える。
    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を同じ章内または別章へ移動する。
    @discardableResult
    func moveEpisode(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) -> Bool {
        guard permitsDocumentInteraction else { return false }
        if selectedEpisodeID == episodeID, selectedChapterID != destinationChapterID {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return false }
        }
        guard document.moveEpisode(
            id: episodeID,
            from: sourceChapterID,
            to: destinationChapterID,
            before: targetEpisodeID
        ) else { return false }
        if selectedEpisodeID == episodeID {
            setSelection(chapterID: destinationChapterID, episodeID: episodeID)
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 選択中章の本文を更新する。編集のたびに呼ばれる想定で、モデル更新は即座に行い、
    /// ディスクへの保存は2秒デバウンスする(テキスト所有権ルール D-005。
    /// `EditorView` から編集中に本文を書き戻すことはしない)。
    func updateSelectedEpisodeContent(_ content: String) {
        guard let selectedChapterID, let selectedEpisodeID else { return }
        updateEpisodeContent(content, for: selectedEpisodeID, in: selectedChapterID)
    }

    /// 表示時に固定した話・章・作品セッションへ本文を反映する。
    ///
    /// 作品遷移前のIME確定通知が、遷移先の「現在選択」へ流れ込まないよう、
    /// EditorViewのcallbackはこのAPIへ固定IDとsessionを渡す。
    func updateEpisodeContent(
        _ content: String,
        for episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken? = nil,
        expectedEditorContentGeneration: UInt64? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        if let expectedEditorContentGeneration {
            guard editorContentGeneration == expectedEditorContentGeneration else { return }
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }),
              let episode = chapter.episodes.first(where: { $0.id == episodeID }),
              episode.content != content else { return }
        let baseContentDigest = deviceSyncDurablePackageDigest(
            for: episodeID,
            fallbackContent: episode.content
        )
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        registerDeviceSyncContentMutation(content, episodeID: episodeID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
        if let expectedSession,
           let expectedEditorContentGeneration,
           let expectedLookup = currentDeviceSyncLookupIdentity,
           expectedLookup.documentSession == expectedSession,
           expectedLookup.chapterID == chapterID,
           expectedLookup.episodeID == episodeID,
           expectedLookup.editorContentGeneration == expectedEditorContentGeneration {
            scheduleDeviceSyncForEditedEpisode(
                content: content,
                expectedLookup: expectedLookup,
                baseContentDigest: baseContentDigest,
                previousContentDigest: SyncContentDigest(content: episode.content)
            )
        }
    }

    func captureCommittedTextForDeviceSync() -> EditorCommittedTextCaptureResult {
        activeCommittedTextCapture()
    }

    func installDeviceSyncEpisodeContent(
        _ content: String,
        chapterID: ChapterID,
        episodeID: EpisodeID,
        advancesEditorGeneration: Bool
    ) {
        let previousContent = document.episode(episodeID)?.episode.content
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        if previousContent != content {
            registerDeviceSyncContentMutation(
                content,
                episodeID: episodeID,
                containsLocalEditIntent: false
            )
        }
        saveCoordinator.markDirty()
        if advancesEditorGeneration {
            editorContentGeneration &+= 1
        }
    }

    func advanceEditorContentGenerationForSurfaceTransition() {
        editorContentGeneration &+= 1
    }

    /// 選択中章のメモを更新する。メモは短文想定の補助情報なので SwiftUI 側の
    /// `TextEditor` から通常の Binding 更新で呼ばれる。
    func updateSelectedEpisodeMemo(_ memo: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedChapterID, let selectedEpisodeID else { return }
        guard selectedEpisode?.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    // MARK: - 登場人物

    /// 登場人物を追加し、追加した人物を選択状態にする。
    func addCharacter() {
        guard permitsDocumentInteraction else { return }
        let newID = document.addCharacter(name: "名無し")
        selectedCharacterID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 登場人物を選択する。
    func selectCharacter(_ id: CharacterID?) {
        guard permitsDocumentInteraction else { return }
        selectedCharacterID = id
    }

    /// 選択中の登場人物を更新する。
    func updateSelectedCharacter(
        name: String? = nil,
        kana: String? = nil,
        memo: String? = nil,
        colorHex: String? = nil,
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        guard permitsDocumentInteraction else { return }
        guard let selectedCharacterID, let current = selectedCharacter else { return }
        let nextName = name ?? current.name
        let nextKana = kana ?? current.kana
        let nextMemo = memo ?? current.memo
        let nextColorHex = colorHex ?? current.colorHex
        let nextRole = role ?? current.role
        let nextAge = age ?? current.age
        let nextGender = gender ?? current.gender
        let nextFirstPerson = firstPerson ?? current.firstPerson
        let nextSecondPerson = secondPerson ?? current.secondPerson
        let nextSpeechStyle = speechStyle ?? current.speechStyle
        let nextAppearance = appearance ?? current.appearance
        let nextPersonality = personality ?? current.personality
        let nextBackground = background ?? current.background

        guard current.name != nextName || current.kana != nextKana || current.memo != nextMemo ||
            current.colorHex != nextColorHex || current.role != nextRole || current.age != nextAge ||
            current.gender != nextGender || current.firstPerson != nextFirstPerson ||
            current.secondPerson != nextSecondPerson || current.speechStyle != nextSpeechStyle ||
            current.appearance != nextAppearance || current.personality != nextPersonality ||
            current.background != nextBackground else {
            return
        }

        document.updateCharacter(
            id: selectedCharacterID,
            name: nextName,
            kana: nextKana,
            memo: nextMemo,
            colorHex: nextColorHex,
            role: nextRole,
            age: nextAge,
            gender: nextGender,
            firstPerson: nextFirstPerson,
            secondPerson: nextSecondPerson,
            speechStyle: nextSpeechStyle,
            appearance: nextAppearance,
            personality: nextPersonality,
            background: nextBackground
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// Optional な登場人物シート項目を更新する。空文字は `nil` として保存する。
    func updateSelectedCharacterProfile(
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        guard permitsDocumentInteraction else { return }
        updateSelectedCharacter(
            role: role.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.role,
            age: age.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.age,
            gender: gender.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.gender,
            firstPerson: firstPerson.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.firstPerson,
            secondPerson: secondPerson.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.secondPerson,
            speechStyle: speechStyle.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.speechStyle,
            appearance: appearance.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.appearance,
            personality: personality.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.personality,
            background: background.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.background
        )
    }

    func updateSelectedCharacterProfileField(_ field: CharacterProfileField, value: String) {
        guard permitsDocumentInteraction else { return }
        guard var current = selectedCharacter else { return }
        let normalized = Self.nilIfBlank(value)

        switch field {
        case .role:
            current.role = normalized
        case .age:
            current.age = normalized
        case .gender:
            current.gender = normalized
        case .firstPerson:
            current.firstPerson = normalized
        case .secondPerson:
            current.secondPerson = normalized
        case .speechStyle:
            current.speechStyle = normalized
        case .appearance:
            current.appearance = normalized
        case .personality:
            current.personality = normalized
        case .background:
            current.background = normalized
        }

        document.updateCharacter(
            id: current.id,
            name: current.name,
            kana: current.kana,
            memo: current.memo,
            colorHex: current.colorHex,
            role: current.role,
            age: current.age,
            gender: current.gender,
            firstPerson: current.firstPerson,
            secondPerson: current.secondPerson,
            speechStyle: current.speechStyle,
            appearance: current.appearance,
            personality: current.personality,
            background: current.background
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の登場人物カラーを更新する。`nil` はカラーなしを表す。
    func updateSelectedCharacterColor(_ colorHex: String?) {
        guard permitsDocumentInteraction else { return }
        guard let selectedCharacterID, let current = selectedCharacter else { return }
        guard current.colorHex != colorHex else { return }

        document.updateCharacter(
            id: selectedCharacterID,
            name: current.name,
            kana: current.kana,
            memo: current.memo,
            colorHex: colorHex,
            role: current.role,
            age: current.age,
            gender: current.gender,
            firstPerson: current.firstPerson,
            secondPerson: current.secondPerson,
            speechStyle: current.speechStyle,
            appearance: current.appearance,
            personality: current.personality,
            background: current.background
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 登場人物名の編集確定時に、空名を正規化して即時保存へ寄せる。
    func commitCharacterEditing() {
        guard permitsDocumentInteraction else { return }
        for character in document.characters {
            let normalizedName = NovelDocument.normalizedCharacterName(character.name)
            if character.name != normalizedName {
                document.updateCharacter(
                    id: character.id,
                    name: normalizedName,
                    kana: character.kana,
                    memo: character.memo,
                    colorHex: character.colorHex,
                    role: character.role,
                    age: character.age,
                    gender: character.gender,
                    firstPerson: character.firstPerson,
                    secondPerson: character.secondPerson,
                    speechStyle: character.speechStyle,
                    appearance: character.appearance,
                    personality: character.personality,
                    background: character.background
                )
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 登場人物を削除する。
    @discardableResult
    func deleteCharacter(id: CharacterID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.characters.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeCharacter(id: id) != nil else { return false }

        if selectedCharacterID == id {
            let fallbackIndex = min(originalIndex, document.characters.count - 1)
            selectedCharacterID = document.characters.indices.contains(fallbackIndex) ?
                document.characters[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 登場人物を並べ替える。
    func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveCharacters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - プロットカード

    /// プロットカードを追加し、追加したカードを選択状態にする。
    func addPlotCard(chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        let newID = document.addPlotCard(title: "新しいカード", chapterID: chapterID)
        selectedPlotCardID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを選択する。
    func selectPlotCard(_ id: PlotCardID?) {
        guard permitsDocumentInteraction else { return }
        selectedPlotCardID = id
    }

    /// 選択中のプロットカードを更新する。
    func updateSelectedPlotCard(title: String? = nil, memo: String? = nil, chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        let nextTitle = title ?? current.title
        let nextMemo = memo ?? current.memo
        let nextChapterID = chapterID ?? current.chapterID

        guard current.title != nextTitle || current.memo != nextMemo || current.chapterID != nextChapterID else {
            return
        }

        document.updatePlotCard(id: selectedPlotCardID, title: nextTitle, memo: nextMemo, chapterID: nextChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中のプロットカードの章紐付けを更新する。`nil` は未紐付けを表す。
    func updateSelectedPlotCardChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        guard current.chapterID != chapterID else { return }

        document.updatePlotCard(id: selectedPlotCardID, title: current.title, memo: current.memo, chapterID: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// プロットカードタイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitPlotCardEditing() {
        guard permitsDocumentInteraction else { return }
        for card in document.plotCards {
            let normalizedTitle = NovelDocument.normalizedPlotCardTitle(card.title)
            if card.title != normalizedTitle {
                document.updatePlotCard(id: card.id, title: normalizedTitle, memo: card.memo, chapterID: card.chapterID)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// プロットカードを削除する。
    @discardableResult
    func deletePlotCard(id: PlotCardID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.plotCards.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removePlotCard(id: id) != nil else { return false }

        if selectedPlotCardID == id {
            let fallbackIndex = min(originalIndex, document.plotCards.count - 1)
            selectedPlotCardID = document.plotCards.indices.contains(fallbackIndex) ?
                document.plotCards[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// プロットカードを並べ替える。
    func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.movePlotCards(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを章レーン内/レーン間で移動する。
    func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        guard permitsDocumentInteraction else { return }
        document.movePlotCard(id: id, toChapter: chapterID, before: targetID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// Plot Outlineへのdropとしてカードの所属先を変更する。
    /// 存在しないカード／章、および現在と同じ所属先へのdropは拒否する。
    @discardableResult
    func movePlotCardFromOutline(id: PlotCardID, to selection: PlotOutlineSelection) -> Bool {
        guard permitsDocumentInteraction else { return false }
        if case let .chapter(chapterID) = selection, chapterID != selectedChapterID {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return false }
        }
        guard let card = document.plotCards.first(where: { $0.id == id }) else { return false }

        let destinationChapterID: ChapterID?
        switch selection {
        case .unassigned:
            destinationChapterID = nil
        case let .chapter(chapterID):
            guard document.chapters.contains(where: { $0.id == chapterID }) else { return false }
            destinationChapterID = chapterID
        }

        guard card.chapterID != destinationChapterID else { return false }

        document.movePlotCard(id: id, toChapter: destinationChapterID)
        selectedPlotCardID = id
        plotOutlineSelection = selection
        if let destinationChapterID {
            setSelection(chapterID: destinationChapterID, episodeID: preferredEpisodeID(in: destinationChapterID))
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    // MARK: - 伏線

    /// 伏線を追加し、追加した伏線を選択状態にする。
    func addFlag() {
        guard permitsDocumentInteraction else { return }
        let newID = document.addFlag(title: "新しい伏線", plantedChapterID: selectedChapterID)
        selectedFlagID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線を選択する。
    func selectFlag(_ id: FlagID?) {
        guard permitsDocumentInteraction else { return }
        selectedFlagID = id
    }

    /// 選択中の伏線を更新する。
    func updateSelectedFlag(title: String? = nil, note: String? = nil) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        let nextTitle = title ?? next.title
        let nextNote = note ?? next.note

        guard next.title != nextTitle || next.note != nextNote else { return }

        next.title = nextTitle
        next.note = nextNote
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の章紐付けを更新する。
    func updateSelectedFlagChapters(plantedChapterID: ChapterID? = nil, resolvedChapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        let nextPlantedChapterID = plantedChapterID ?? next.plantedChapterID
        let nextResolvedChapterID = resolvedChapterID ?? next.resolvedChapterID

        guard next.plantedChapterID != nextPlantedChapterID || next.resolvedChapterID != nextResolvedChapterID else {
            return
        }

        next.plantedChapterID = nextPlantedChapterID
        next.resolvedChapterID = nextResolvedChapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の張った章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagPlantedChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        guard next.plantedChapterID != chapterID else { return }

        next.plantedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagResolvedChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        guard next.resolvedChapterID != chapterID else { return }

        next.resolvedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収状態を反転する。
    func toggleSelectedFlagResolved() {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        next.isResolved.toggle()
        next.resolvedChapterID = next.isResolved ? selectedChapterID : nil
        document.updateFlag(next)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線タイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitFlagEditing() {
        guard permitsDocumentInteraction else { return }
        for flag in document.flags {
            let normalizedTitle = NovelDocument.normalizedFlagTitle(flag.title)
            if flag.title != normalizedTitle {
                var next = flag
                next.title = normalizedTitle
                document.updateFlag(next)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 伏線を削除する。
    @discardableResult
    func deleteFlag(id: FlagID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.flags.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeFlag(id: id) != nil else { return false }

        if selectedFlagID == id {
            let fallbackIndex = min(originalIndex, document.flags.count - 1)
            selectedFlagID = document.flags.indices.contains(fallbackIndex) ? document.flags[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 伏線を並べ替える。
    func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveFlags(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - 資料添付

    /// 現在のリポジトリが資料添付に対応しているか。
    var supportsAttachments: Bool {
        attachmentManager != nil
    }

    /// 資料一覧を保存層から再読み込みする。
    func reloadAttachments(expectedSession: DocumentSessionToken? = nil) async {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: ()) {
            let packageURL = documentURL
            attachments = await saveCoordinator.performExclusive {
                await loadAttachments(for: packageURL)
            }
        }
    }

    /// 外部ファイルを現在の作品へ資料として取り込む。
    ///
    /// 添付ファイルのコピーは大きなファイルだと数秒かかることがあり、その間に
    /// 本文編集のデバウンス保存(2秒)が発火すると、保存側は「取り込み中の古い
    /// attachments/ をコピーした作業ディレクトリ」でパッケージを全置換してしまい、
    /// 取り込んだ資料が失われる(Phase 4 レビュー F-A)。そこで、まず
    /// `saveCoordinator.saveNow()` で保留中の編集を先に排出したうえで、実際の
    /// ファイルコピーと一覧再読込みは `saveCoordinator.performExclusive` の中で
    /// 行い、その間は新しい保存が一切始まらないようにする。
    ///
    /// - Important: `saveNow()` は `performExclusive` の *外側* で呼ぶこと。
    ///   `performExclusive` の中から `saveNow()` を呼ぶと、排他区間そのものを
    ///   待つ形になりデッドロックする。
    @discardableResult
    func addAttachment(
        from sourceURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Attachment? {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: nil) {
            await addAttachmentSerially(from: sourceURL)
        }
    }

    private func addAttachmentSerially(from sourceURL: URL) async -> Attachment? {
        guard let attachmentManager else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }
        let packageURL = documentURL

        return await saveCoordinator.performExclusive {
            do {
                let attachment = try await attachmentManager.addAttachment(from: sourceURL, to: packageURL)
                attachments = await loadAttachments(for: packageURL)
                return attachment
            } catch {
                print("[FUMINIWA] 資料の取り込みに失敗しました(\(Self.errorCategory(error)))")
                return nil
            }
        }
    }

    /// 作品から資料を削除する。添付操作と保存の直列化は `addAttachment` と同じ理由
    /// (Phase 4 レビュー F-A)。
    func deleteAttachment(
        _ attachment: Attachment,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await deleteAttachmentSerially(attachment)
        }
    }

    private func deleteAttachmentSerially(_ attachment: Attachment) async -> Bool {
        guard let attachmentManager else { return false }
        guard await saveCoordinator.saveNow() else { return false }
        let packageURL = documentURL

        return await saveCoordinator.performExclusive {
            do {
                try await attachmentManager.deleteAttachment(named: attachment.fileName, from: packageURL)
                attachments = await loadAttachments(for: packageURL)
                return true
            } catch {
                print("[FUMINIWA] 資料の削除に失敗しました(\(attachment.fileName), \(Self.errorCategory(error)))")
                return false
            }
        }
    }

    /// プレビュー用の資料URLを返す。
    func attachmentPreviewURL(for attachment: Attachment) -> URL? {
        attachmentManager?.attachmentURL(named: attachment.fileName, in: documentURL)
    }

    /// 現在の作品状態をスナップショットとして保存する。
    ///
    /// まず通常保存を完了させてから、対応リポジトリにスナップショット作成を依頼する。
    /// 非対応リポジトリの場合は `nil` を返す。
    func createSnapshot(expectedSession: DocumentSessionToken? = nil) async -> URL? {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: nil) {
            await createSnapshotSerially()
        }
    }

    private func createSnapshotSerially() async -> URL? {
        guard let repository = repository as? SnapshottingDocumentRepository else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }
        let documentSnapshot = document
        let packageURL = documentURL

        do {
            return try await saveCoordinator.performExclusive {
                try await repository.saveSnapshot(documentSnapshot, to: packageURL)
            }
        } catch {
            print("[FUMINIWA] スナップショット保存に失敗しました(\(Self.errorCategory(error)))")
            return nil
        }
    }

    /// 現在の作品パッケージに保存されているスナップショットを新しい順で返す。
    func listSnapshots(expectedSession: DocumentSessionToken? = nil) async -> [DocumentSnapshotInfo] {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: []) {
            await listSnapshotsSerially()
        }
    }

    private func listSnapshotsSerially() async -> [DocumentSnapshotInfo] {
        guard let repository = repository as? SnapshottingDocumentRepository else { return [] }
        let packageURL = documentURL

        do {
            return try await saveCoordinator.performExclusive {
                try await repository.listSnapshots(in: packageURL)
            }
        } catch {
            print("[FUMINIWA] スナップショット一覧の取得に失敗しました(\(Self.errorCategory(error)))")
            return []
        }
    }

    /// 指定スナップショットを現在の作品へ復元する。
    ///
    /// 復元は破壊的でないよう、現在状態を先にスナップショット化してから書き戻す。
    /// 失敗時は `documentURL` / 本文 / 資料一覧を切り替えない(docs/PHASE5.md 4.5-3a)。
    @discardableResult
    func restoreSnapshot(
        at snapshotURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await restoreSnapshotSerially(at: snapshotURL)
        }
    }

    private func restoreSnapshotSerially(at snapshotURL: URL) async -> Bool {
        guard let repository = repository as? SnapshottingDocumentRepository else { return false }

        let restoredDocument: NovelDocument
        let restoredAttachments: [Attachment]
        do {
            restoredDocument = try await repository.load(from: snapshotURL)
            restoredAttachments = try await loadAttachmentsThrowing(for: snapshotURL)
        } catch {
            print("[FUMINIWA] スナップショットの読み込みに失敗しました(\(Self.errorCategory(error)))")
            return false
        }

        guard beginDocumentTransition() else { return false }
        defer { endDocumentTransition() }
        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        ) else { return false }

        // ここから復元結果のinstallまでは編集面を閉じる。復元中の入力が退避後に
        // 失われることを防ぎ、保存Coordinatorにも現在作品を公開しない(D-041)。
        let currentDocument = document
        let packageURL = documentURL
        startupState = .loading

        // 復元前退避と書き戻しを同じ保存排他区間で行う。通常保存が間へ入り、
        // snapshot directoryやpackage全体を別revisionで置換することを防ぐ。
        do {
            try await saveCoordinator.performExclusive {
                _ = try await repository.saveSnapshot(currentDocument, to: packageURL)
                try await repository.restoreSnapshot(from: snapshotURL, into: packageURL)
                // 待機中の通常保存が復元前モデルを同じpackageへ戻さないよう、
                // 復元結果のinstallも排他区間内で確定する。
                installDocument(restoredDocument, at: packageURL, attachments: restoredAttachments)
            }
        } catch {
            startupState = .ready
            print("[FUMINIWA] スナップショットの退避または復元に失敗しました(\(Self.errorCategory(error)))")
            return false
        }

        return true
    }

    // MARK: - 保存

    /// アプリ終了前に、保留中のデバウンス保存をキャンセルして現在状態を保存する。
    func saveBeforeTermination() async -> Bool {
        if let terminationTask {
            return await terminationTask.value
        }

        isTerminationPending = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            let succeeded = await documentOperationGate.perform {
                await saveBeforeTerminationSerially()
            }
            if !succeeded {
                // 終了が取り消された後は、利用者が保存先や作品を変更して復旧できる。
                isTerminationPending = false
                terminationTask = nil
            }
            return succeeded
        }
        terminationTask = task
        return await task.value
    }

    private func saveBeforeTerminationSerially() async -> Bool {
        guard startupState.isReady else { return true }
        guard beginDocumentTransition() else { return false }
        let succeeded = await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        )
        if !succeeded {
            endDocumentTransition()
        }
        return succeeded
    }

    /// Fileメニューの明示保存。自動保存と同じ直列化経路を使う。
    @discardableResult
    func saveNow() async -> Bool {
        guard startupState.isReady else { return false }
        return await saveCoordinator.saveNow()
    }

    /// 保存失敗後に、現在の未保存 revision を明示的に再試行する。
    func retrySave() {
        guard startupState.isReady else { return }
        flushSaveImmediately()
    }

    /// 保留中のデバウンス保存をキャンセルし、即座に保存キューへ流す(fire-and-forget)。
    /// `saveCoordinator.saveNow()` 自体がデバウンスのキャンセルと dirty 分の
    /// 保存until-cleanを面倒見るため、ここでは呼び出すだけでよい。
    private func flushSaveImmediately() {
        guard startupState.isReady else { return }
        Task { await self.saveCoordinator.saveNow() }
    }

    private func handleSaveEvent(_ event: DocumentSaveCoordinator.SaveEvent) {
        switch event {
        case .dirty:
            saveState = .unsaved
        case .saving:
            saveState = .saving
        case .saved:
            saveState = .saved
        case .failed:
            saveState = .failed
        }
    }

    private func normalizedChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
    }

    private func normalizedEpisodeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Episode.defaultTitle : trimmed
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func loadAttachments(for url: URL) async -> [Attachment] {
        do {
            return try await loadAttachmentsThrowing(for: url)
        } catch {
            print("[FUMINIWA] 資料一覧の読み込みに失敗しました(\(Self.errorCategory(error)))")
            return []
        }
    }

    private func loadAttachmentsThrowing(for url: URL) async throws -> [Attachment] {
        guard let attachmentManager else { return [] }
        return try await attachmentManager.listAttachments(in: url)
    }

    func saveDocumentPackage(_ document: NovelDocument, to url: URL) async throws {
        try await repository.save(document, to: url)
    }

    /// D-061のremote/merge snapshotを、prepared Editor境界の中でpackageへ先に
    /// atomic保存してからmemoryへinstallする。同じdocument session以外へは適用しない。
    func persistAndInstallWorkSyncSnapshot(
        _ snapshot: WorkSnapshot,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared,
              documentSessionToken == expectedSession else { return false }
        let synchronizedDocument: NovelDocument
        do {
            synchronizedDocument = try snapshot.materializedDocument()
        } catch {
            return false
        }
        guard synchronizedDocument.id == expectedSession.documentID else { return false }
        do {
            return try await saveCoordinator.performExclusive {
                guard documentSessionToken == expectedSession,
                      documentURL.standardizedFileURL == expectedSession.documentURL else { return false }
                try deviceSyncRuntime?.setup?.validatePrivateWorkingCopy(documentURL)
                try await repository.save(synchronizedDocument, to: documentURL)
                try deviceSyncRuntime?.setup?.validatePrivateWorkingCopy(documentURL)
                let loadedDocument = try await repository.load(from: documentURL)
                try deviceSyncRuntime?.setup?.validatePrivateWorkingCopy(documentURL)
                guard documentSessionToken == expectedSession,
                      documentURL.standardizedFileURL == expectedSession.documentURL,
                      loadedDocument.id == expectedSession.documentID,
                      try WorkSnapshot(document: loadedDocument) == snapshot else { return false }
                guard await recordLocalLibraryPackageSave(loadedDocument, at: documentURL) else {
                    return false
                }

                let previousChapterID = selectedChapterID
                let previousEpisodeID = selectedEpisodeID
                let previousCharacterID = selectedCharacterID
                let previousPlotCardID = selectedPlotCardID
                let previousFlagID = selectedFlagID
                let previousWorldNoteID = selectedWorldNoteID
                // repositoryから読み戻してexact一致したinstanceだけをEditorへ入れる。
                document = loadedDocument
                noteDeviceSyncPackageSaved(loadedDocument)
                editorContentGeneration &+= 1

                if let previousChapterID,
                   let previousEpisodeID,
                   loadedDocument.chapters.contains(where: { chapter in
                       chapter.id == previousChapterID
                           && chapter.episodes.contains(where: { $0.id == previousEpisodeID })
                   }) {
                    selectedChapterID = previousChapterID
                    selectedEpisodeID = previousEpisodeID
                } else {
                    setInitialSelection(for: loadedDocument)
                }
                selectedCharacterID = previousCharacterID.flatMap { id in
                    loadedDocument.characters.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.characters.first?.id
                selectedPlotCardID = previousPlotCardID.flatMap { id in
                    loadedDocument.plotCards.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.plotCards.first?.id
                selectedFlagID = previousFlagID.flatMap { id in
                    loadedDocument.flags.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.flags.first?.id
                selectedWorldNoteID = previousWorldNoteID.flatMap { id in
                    loadedDocument.worldNotes.contains(where: { $0.id == id }) ? id : nil
                } ?? loadedDocument.worldNotes.first?.id
                saveState = .saved
                return true
            }
        } catch {
            return false
        }
    }

    /// D-061のlocal recovery／conflict choice前に、現在のpackageを保存層から
    /// 読み戻してexact snapshotを得る。memory上の編集中値だけを根拠にremote版を
    /// materializeせず、atomic save済みの版だけをcoordinatorへ渡す。
    func readCurrentWorkSyncPackageSnapshotAtPreparedBoundary(
        expectedSession: DocumentSessionToken
    ) async -> WorkSnapshot? {
        guard editorCommandSession.isDocumentTransitionPrepared,
              documentSessionToken == expectedSession else { return nil }
        do {
            return try await saveCoordinator.performExclusive {
                guard documentSessionToken == expectedSession,
                      documentURL.standardizedFileURL == expectedSession.documentURL else { return nil }
                let loadedDocument = try await repository.load(from: documentURL)
                guard loadedDocument.id == expectedSession.documentID else { return nil }
                return try WorkSnapshot(document: loadedDocument)
            }
        } catch {
            return nil
        }
    }

    private func installDocument(
        _ newDocument: NovelDocument,
        at url: URL,
        attachments newAttachments: [Attachment]
    ) {
        guard !deviceSyncStartupFailedSafely else { return }
        document = newDocument
        documentURL = url
        noteDeviceSyncPackageSaved(newDocument)
        advanceDocumentSession(document: newDocument, url: url)
        editorContentGeneration &+= 1
        setInitialSelection(for: newDocument)
        deviceSyncSelectionDidChange()
        selectedCharacterID = newDocument.characters.first?.id
        selectedPlotCardID = newDocument.plotCards.first?.id
        selectedFlagID = newDocument.flags.first?.id
        attachments = newAttachments
        saveState = .saved
        startupState = .ready
        rememberDocumentURL(url)
    }

    private func advanceDocumentSession(document: NovelDocument, url: URL) {
        documentSessionToken = DocumentSessionToken(
            generation: documentSessionToken.generation &+ 1,
            documentID: document.id,
            documentURL: url.standardizedFileURL
        )
    }

    private func setInitialSelection(for newDocument: NovelDocument) {
        lastSelectedEpisodeByChapter = [:]
        let chapterID = newDocument.chapters.first?.id
        let episodeID = newDocument.chapters.first?.episodes.first?.id
        setSelection(chapterID: chapterID, episodeID: episodeID)
        selectedWorldNoteID = newDocument.worldNotes.first?.id
        plotOutlineSelection = chapterID.map(PlotOutlineSelection.chapter) ?? .unassigned
    }

    private func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        let didChange = selectedChapterID != chapterID || selectedEpisodeID != episodeID
        guard !didChange || permitsSynchronousDeviceSyncSelectionMutation else { return }
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        if let chapterID, let episodeID {
            lastSelectedEpisodeByChapter[chapterID] = episodeID
        }
        if let chapterID {
            plotOutlineSelection = .chapter(chapterID)
        }
        workspaceSelection.outlineItemID = chapterID.map { OutlineItemID(rawValue: $0.rawValue.uuidString) }
        if didChange {
            deviceSyncSelectionDidChange()
        }
    }

    private var permitsSynchronousDeviceSyncSelectionMutation: Bool {
        if usesWholeWorkSyncRuntime, !usesNoteSyncRuntime, deviceSyncLocalRecoveryPending {
            return false
        }
        return deviceSyncRuntime == nil ||
            activeDeviceSyncIdentity == nil ||
            permitsDeviceSyncSelectionMutationAfterFlush ||
            editorCommandSession.isDocumentTransitionPrepared
    }

    private func preferredEpisodeID(in chapterID: ChapterID) -> EpisodeID? {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return nil }
        if let remembered = lastSelectedEpisodeByChapter[chapterID], chapter.episodes.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return chapter.episodes.first?.id
    }

    private func observeResignActive() {
        guard resignActiveObserver.value == nil else { return }
        resignActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDeviceSyncForBackground(waitForRemote: false)
            }
        }
    }

    private func observeSystemSleep() {
        guard systemSleepObserver.value == nil else { return }
        systemSleepObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDeviceSyncForBackground(waitForRemote: false)
            }
        }
    }

    private func observeDeviceSyncReactivation() {
        guard becomeActiveObserver.value == nil, systemWakeObserver.value == nil else { return }
        becomeActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceSyncReactivation()
            }
        }
        systemWakeObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceSyncReactivation()
            }
        }
    }

    /// AppKit activation notifications are signals only. The notification
    /// callback schedules remote work and returns without awaiting CloudKit.
    private func scheduleDeviceSyncReactivation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case let .documentSelection(context) = startupState,
               context.presentation == .cloudLibrary {
                await refreshStartupLibrary()
            } else {
                await retryAccountScopedPendingPublicationsInBackground()
                await refreshActiveDeviceSyncWithoutPreparing()
            }
        }
    }

    private func rememberDocumentURL(_ url: URL) {
        guard deviceSyncRuntime?.library == nil else { return }
        userDefaults.set(url.path, forKey: Self.recentDocumentPathKey)
    }

    // MARK: - 既定の保存先

    private static func defaultDirectory(fileManager: FileManager, directoryName: String) -> URL {
        #if DEBUG
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent("Drafts", isDirectory: true)
        }
        #endif
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func defaultSaveURL(
        forTitle title: String,
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        defaultDirectory(fileManager: fileManager, directoryName: directoryName)
            .appendingPathComponent("\(title).novelpkg", isDirectory: true)
    }

    /// 既定保存先の `<title>.novelpkg` を返す。
    /// 既に同名のパッケージが存在する場合は連番を振って重複を避ける。
    private static func availableSaveURL(
        forTitle title: String,
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        let directory = defaultDirectory(fileManager: fileManager, directoryName: directoryName)

        var candidate = directory.appendingPathComponent("\(title).novelpkg", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(title)\(suffix).novelpkg", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
