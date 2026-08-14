import Darwin
import Foundation
import NovelCore
import NovelSync
import os

#if canImport(NovelSyncCloudKit)
import NovelSyncCloudKit
#endif

enum DeviceSyncLog {
    private static let noteLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "note-sync"
    )
    private static let libraryLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "cloud-library"
    )

    /// Debug ビルドは既定オン。Scheme の環境変数 `FUMINIWA_NOTE_SYNC_DEBUG=0/1` で上書きできる。
    static var isDebugEnabled: Bool {
        switch ProcessInfo.processInfo.environment["FUMINIWA_NOTE_SYNC_DEBUG"] {
        case "1": true
        case "0": false
        default:
            #if DEBUG
            true
            #else
            false
            #endif
        }
    }

    static func token(_ error: any Error) -> String {
        #if canImport(NovelSyncCloudKit)
        CloudKitSyncDiagnostic.token(for: error)
        #else
        String(reflecting: type(of: error))
        #endif
    }

    static func userFacingMessage(_ message: String, error: any Error) -> String {
        guard isDebugEnabled else { return message }
        return "\(message)\n\n\(token(error))"
    }

    static func event(_ name: String, error: (any Error)? = nil) {
        emit(prefix: "cloud-library", name: name, error: error, logger: libraryLogger)
    }

    static func note(_ name: String, error: (any Error)? = nil) {
        emit(prefix: "note-sync", name: name, error: error, logger: noteLogger)
    }

    static func looksTemporarilyOffline(_ error: any Error) -> Bool {
        #if canImport(NovelSyncCloudKit)
        CloudKitSyncDiagnostic.looksTemporarilyOffline(error)
        #else
        false
        #endif
    }

    private static func emit(
        prefix: String,
        name: String,
        error: (any Error)?,
        logger: Logger
    ) {
        let line = if let error {
            "\(prefix) \(name)(\(token(error)))"
        } else {
            "\(prefix) \(name)"
        }
        print("[FUMINIWA] \(line)")
        if error != nil {
            logger.error("\(line, privacy: .public)")
        } else if isDebugEnabled {
            logger.info("\(line, privacy: .public)")
        }
    }
}

enum DeviceSyncLocalPersistenceError: Error {
    case editIntentUnavailable
    case invalidEditIntent
}

/// App層がDevice Syncを有効化するための任意注入値。
///
/// `nil`なら従来のapp-private package執筆だけで動く。
/// CloudKitの具象型やcontainer設定はAppStateへ露出さない。
struct DeviceSyncRuntime {
    let replicaID: SyncReplicaID
    let transport: any EpisodeSyncTransport
    /// D-061の作品全体同期。`nil`のruntimeはD-060の話本文同期だけを使う。
    /// 既存test fakeとExperimental buildを壊さず、production compositionが
    /// additiveなWork transportを注入した時だけ切り替える。
    let workTransport: (any WorkSyncTransport)?
    /// CloudKit/account bootstrapを待たず、端末内bindingとwork journalだけを
    /// 復元する入口。productionのEditor preflightは必ずこちらを先に使う。
    let localWorkBinding: (@Sendable (
        DocumentSessionToken,
        SyncWorkStructureDigest
    ) async throws -> DeviceSyncBindingResolution?)?
    let binding: @Sendable (
        DocumentSessionToken,
        SyncWorkStructureDigest
    ) async throws -> DeviceSyncBindingResolution?
    let remoteChangeSignals: AsyncStream<Void>?
    let mergeRecoveryStore: any DeviceSyncMergeRecoveryStoring
    let editIntentStore: any DeviceSyncEditIntentStoring
    let setup: DeviceSyncSetupRuntime?
    /// D-063のcloud-first作品棚。`nil`はExperimental/legacy transportだけ。
    let library: DeviceSyncLibraryRuntime?
    /// D-071のentity同期。`nil`ならD-061 WorkSyncCoordinator経路を使う。
    let makeNoteSyncCoordinator: (@Sendable (SyncWorkID, LocalWorkingCopyID) async throws -> NoteSyncCoordinator)?
    let now: @Sendable () -> Date
    let leaseDuration: TimeInterval

    init(
        replicaID: SyncReplicaID,
        transport: any EpisodeSyncTransport,
        workTransport: (any WorkSyncTransport)? = nil,
        localWorkBinding: (@Sendable (
            DocumentSessionToken,
            SyncWorkStructureDigest
        ) async throws -> DeviceSyncBindingResolution?)? = nil,
        binding: @escaping @Sendable (
            DocumentSessionToken,
            SyncWorkStructureDigest
        ) async throws -> DeviceSyncBindingResolution?,
        remoteChangeSignals: AsyncStream<Void>? = nil,
        mergeRecoveryStore: any DeviceSyncMergeRecoveryStoring = InMemoryDeviceSyncMergeRecoveryStore(),
        editIntentStore: any DeviceSyncEditIntentStoring = InMemoryDeviceSyncEditIntentStore(),
        setup: DeviceSyncSetupRuntime? = nil,
        library: DeviceSyncLibraryRuntime? = nil,
        makeNoteSyncCoordinator: (@Sendable (
            SyncWorkID,
            LocalWorkingCopyID
        ) async throws -> NoteSyncCoordinator)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        leaseDuration: TimeInterval = 120
    ) {
        self.replicaID = replicaID
        self.transport = transport
        self.workTransport = workTransport
        self.localWorkBinding = localWorkBinding
        self.binding = binding
        self.remoteChangeSignals = remoteChangeSignals
        self.mergeRecoveryStore = mergeRecoveryStore
        self.editIntentStore = editIntentStore
        self.setup = setup
        self.library = library
        self.makeNoteSyncCoordinator = makeNoteSyncCoordinator
        self.now = now
        self.leaseDuration = leaseDuration
    }

    func leaseExpiration() -> Date {
        now().addingTimeInterval(leaseDuration)
    }
}

enum DeviceSyncLibraryConnection: Equatable, Sendable {
    case available
    case offline
    case accountRequired
    case differentAccount
}

enum DeviceSyncRemoteLibraryAvailability: Equatable, Sendable {
    /// Domain bindingだけ。Appのpackage readbackを通るまではcachedではない。
    case locallyBound
    case remoteOnly
    case remoteDownloadPending
    case publishPending
}

struct DeviceSyncRemoteLibraryEntry: Equatable, Sendable, Identifiable {
    var id: SyncWorkID {
        work.workID
    }

    let work: SyncWorkLibraryEntry
    let availability: DeviceSyncRemoteLibraryAvailability
}

struct DeviceSyncRemoteLibrarySnapshot: Equatable, Sendable {
    let entries: [DeviceSyncRemoteLibraryEntry]
    let connection: DeviceSyncLibraryConnection
}

struct DeviceSyncPreparedLibraryWork: Sendable {
    let entry: SyncWorkLibraryEntry
    let document: NovelDocument
    let packageSnapshot: WorkSnapshot
    let bind: @Sendable (WorkSnapshot) async throws -> Void
}

/// AppStateからCloudKit具象型を隠しつつ、local intent→package→remote bindの
/// 順序をtest fakeでもexactに再現するclosure集合。
struct DeviceSyncLibraryRuntime: Sendable {
    let loadLocalInventory: @Sendable () async throws -> DeviceSyncLocalLibraryInventory
    let loadRemoteLibrary: @Sendable () async throws -> DeviceSyncRemoteLibrarySnapshot
    let packageURL: @Sendable (SyncWorkID) async throws -> URL
    let workIDForPackageURL: @Sendable (URL) async throws -> SyncWorkID?
    let stagingPackageURL: @Sendable (SyncWorkID) async throws -> URL
    let validateStagingPackage: @Sendable (URL, SyncWorkID) async throws -> Void
    let installStagingPackage: @Sendable (URL, SyncWorkID) async throws -> URL
    let discardStagingPackage: @Sendable (URL, SyncWorkID) async throws -> Void
    let validateInstalledPackage: @Sendable (SyncWorkID) async throws -> Void
    let reserveForPublish: @Sendable (
        SyncWorkID,
        DeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let abortPublishReservation: @Sendable (SyncWorkID) async throws -> Void
    let confirmPublishPackage: @Sendable (
        SyncWorkID,
        DeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let attestPublishStaging: @Sendable (
        SyncWorkID,
        DeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let beginRemoteOpen: @Sendable (SyncWorkLibraryEntry) async throws -> Void
    let attestRemotePackage: @Sendable (
        SyncWorkID,
        DeviceSyncLocalPackageAttestation,
        SyncWorkLibraryEntry
    ) async throws -> Void
    let prepareRemoteOpen: @Sendable (
        SyncWorkLibraryEntry
    ) async throws -> DeviceSyncPreparedLibraryWork
    /// App registryに残ったexact pending intentを再開する。download済みrevisionは
    /// account/networkが使えなくてもDomainのhidden journalから復元できる。
    let resumeRemoteOpen: @Sendable (
        SyncWorkID
    ) async throws -> DeviceSyncPreparedLibraryWork
    /// hidden journalにfull exact revisionがあり、通信なしでpackage化できるか。
    let canResumeRemoteOpenOffline: @Sendable (SyncWorkID) async -> Bool
    /// Domain側だけにdurable化されたremote-open intentを、作品名を漏らさず
    /// Appの作品棚へ復旧候補として合流するためのidentity一覧。
    let offlineResumableRemoteOpenWorkIDs: @Sendable () async -> [SyncWorkID]
    /// App registry更新直前のkill窓で、canonical bindingとimmutable remote
    /// baselineが既に完成しているかをDomain journalだけから確認する。
    let hasCompletedRemoteOpenLocally: @Sendable (SyncWorkLibraryEntry) async -> Bool
    /// canonical local binding/work journalに未解決reviewが残るか。I/O失敗は
    /// registryの旧syncedを信頼しないためthrowsでAppへ返す。
    let localWorkNeedsReview: @Sendable (SyncWorkID, UUID) async throws -> Bool
    let markSynced: @Sendable (SyncWorkID, SyncWorkLibraryEntry) async throws -> Void
    let markNeedsReview: @Sendable (SyncWorkID) async throws -> Void
    let quarantineInstalledPackage: @Sendable (
        SyncWorkID,
        DeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let recordPackageMutation: @Sendable (
        SyncWorkID,
        DeviceSyncLocalPackageAttestation
    ) async throws -> Void
    /// current account scope内に同じcanonical WorkID/document bindingが既に
    /// durableか。registry-onlyの未scoped作品を自動publishしないためのfence。
    let hasLocalPublishAuthority: @Sendable (SyncWorkID, UUID) async -> Bool
    let publishNewWork: @Sendable (SyncWorkID, NovelDocument, URL) async throws -> Void
    /// 作品棚でだけ使うkill-recovery。root/bindingを冪等確認した後、active
    /// editorとは共有しないhidden coordinatorで既存outboxを一度だけ再送する。
    let resumeInitialWorkPublication: @Sendable (
        SyncWorkID,
        NovelDocument,
        URL
    ) async throws -> Void
    /// D-072: この端末のregistryとhidden packageだけを外す。CloudKitは消さない。
    let removeLocalWork: @Sendable (SyncWorkID) async throws -> Void
}

struct DeviceSyncSetupRuntime: Sendable {
    /// cloud-first libraryで新規／import／remote bootstrap用の隠し作業コピーを
    /// 毎回新しいURLとして払い出す。`nil`はlegacy setup runtime。
    let newPrivateWorkingCopyDestination: (@Sendable () throws -> URL)?
    /// `nil`なら現在URLはapp-private。URLを返した場合は、同期操作前に
    /// package全体をそこへcopy-inし、新しいdocument sessionへ切り替える。
    let privateWorkingCopyDestination: @Sendable (DocumentSessionToken) throws -> URL?
    /// copy完了後、URL/recent/sessionを採用する前にfixed rootと
    /// package rootのidentityを検査する。
    let validatePrivateWorkingCopy: @Sendable (URL) throws -> Void
    let candidates: @Sendable (
        DocumentSessionToken,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor]
    let startNew: @Sendable (
        DocumentSessionToken,
        SyncWorkDescriptor,
        [EpisodeID]
    ) async throws -> Void
    let bindExisting: @Sendable (
        DocumentSessionToken,
        UUID,
        SyncWorkStructureDigest,
        SyncWorkID,
        [EpisodeID]
    ) async throws -> Void

    init(
        newPrivateWorkingCopyDestination: (@Sendable () throws -> URL)? = nil,
        privateWorkingCopyDestination: @escaping @Sendable (DocumentSessionToken) throws -> URL?,
        validatePrivateWorkingCopy: @escaping @Sendable (URL) throws -> Void,
        candidates: @escaping @Sendable (
            DocumentSessionToken,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> [SyncWorkDescriptor],
        startNew: @escaping @Sendable (
            DocumentSessionToken,
            SyncWorkDescriptor,
            [EpisodeID]
        ) async throws -> Void,
        bindExisting: @escaping @Sendable (
            DocumentSessionToken,
            UUID,
            SyncWorkStructureDigest,
            SyncWorkID,
            [EpisodeID]
        ) async throws -> Void
    ) {
        self.newPrivateWorkingCopyDestination = newPrivateWorkingCopyDestination
        self.privateWorkingCopyDestination = privateWorkingCopyDestination
        self.validatePrivateWorkingCopy = validatePrivateWorkingCopy
        self.candidates = candidates
        self.startNew = startNew
        self.bindExisting = bindExisting
    }
}

enum DeviceSyncSetupState: Equatable {
    case idle
    case loading
    case candidates([SyncWorkDescriptor])
    case configured
    case unavailable(message: String)
}

struct PendingDeviceSyncNewWork {
    let session: DocumentSessionToken
    let structureDigest: SyncWorkStructureDigest
    let descriptor: SyncWorkDescriptor
}

enum DeviceSyncTransferState: Hashable {
    case notApplicable
    case localPending
    case uploading
    case upToDate

    var logToken: String {
        switch self {
        case .notApplicable: "notApplicable"
        case .localPending: "localPending"
        case .uploading: "uploading"
        case .upToDate: "upToDate"
        }
    }
}

enum DeviceSyncRemoteAvailability: Hashable, Sendable {
    case available
    case temporarilyOffline
    case configurationBlocked

    var logToken: String {
        switch self {
        case .available: "available"
        case .temporarilyOffline: "temporarilyOffline"
        case .configurationBlocked: "configurationBlocked"
        }
    }
}

struct DeviceSyncBindingResolution: Sendable {
    let binding: SyncWorkingCopyBinding
    /// `nil`はremote account/catalogを確認できない間に、端末内のexact bindingだけを
    /// 復元した状態。local journalへ保存できるが、Appがremote送信可と解釈してはならない。
    let descriptor: SyncWorkDescriptor?
    let journal: any EpisodeSyncJournal
    /// D-061の作品snapshot journal。legacy bindingでは`nil`のままD-060へ戻る。
    let workJournal: (any WorkSyncJournal)?
    let allowedEpisodeIDs: Set<EpisodeID>
    let remoteAvailability: DeviceSyncRemoteAvailability

    init(
        binding: SyncWorkingCopyBinding,
        descriptor: SyncWorkDescriptor?,
        journal: any EpisodeSyncJournal,
        workJournal: (any WorkSyncJournal)? = nil,
        allowedEpisodeIDs: Set<EpisodeID>,
        remoteAvailability: DeviceSyncRemoteAvailability? = nil
    ) {
        self.binding = binding
        self.descriptor = descriptor
        self.journal = journal
        self.workJournal = workJournal
        self.allowedEpisodeIDs = allowedEpisodeIDs
        self.remoteAvailability = remoteAvailability ?? (descriptor == nil ? .temporarilyOffline : .available)
    }
}

enum DeviceSyncUIState: Hashable {
    case unconfigured
    case episodeNotIncluded
    case writer
    case readOnly
    case forcing
    case offlineLocal
    case needsReview
    case conflict(EpisodeConflict)
    case syncing
    case blocked

    var allowsEditing: Bool {
        // D-060: this state describes remote propagation, not permission to type
        // into the local editor. Document lifecycle safety remains a separate gate.
        true
    }

    var isConfigured: Bool {
        self != .unconfigured
    }
}

enum DeviceSyncLocalDurabilityState: Hashable {
    case notApplicable
    case pending
    case saved
    /// `.novelpkg`はatomic保存済みだが、作品同期journalのstage/confirmだけを
    /// 完了できなかった。端末保存失敗と表示してはならない。
    case savedSyncPreparationFailed
    case failed
}

enum DeviceSyncEditorStatusKind: Hashable {
    case savingLocally
    case savedLocally
    case syncing
    case synced
    case offline
    case needsReview
    case configurationError
    case syncPreparationError
    case localSaveError

    var systemImage: String {
        switch self {
        case .savingLocally, .syncing:
            "arrow.triangle.2.circlepath.icloud"
        case .savedLocally:
            "checkmark.circle"
        case .synced:
            "checkmark.icloud"
        case .offline:
            "icloud.slash"
        case .needsReview:
            "exclamationmark.icloud"
        case .configurationError, .syncPreparationError:
            "exclamationmark.icloud"
        case .localSaveError:
            "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .savingLocally:
            "この端末へ保存中"
        case .savedLocally:
            "この端末に保存済み"
        case .syncing:
            "この端末に保存済み、iCloudへ同期中"
        case .synced:
            "作品データをこの端末とiCloudに同期済み"
        case .offline:
            "この端末に保存済み、オフライン"
        case .needsReview:
            "この端末に保存済み、統合が必要"
        case .configurationError:
            "この端末に保存済み、同期設定を確認"
        case .syncPreparationError:
            "この端末に保存済み、同期準備を再試行"
        case .localSaveError:
            "この端末への保存に失敗"
        }
    }

    var detail: String {
        switch self {
        case .savingLocally:
            "変更内容をこの端末へ保存しています。入力はそのまま続けられます。"
        case .savedLocally:
            "変更内容はこの端末に保存されています。iCloudへ送るには「iCloudと同期」またはCommand-Sを使います。"
        case .syncing:
            "変更内容はこの端末に保存されています。iCloudへの反映を続けています。"
        case .synced:
            "作品データはこの端末とiCloudに保存されています。資料、スナップショット履歴、端末設定はこの端末だけに保存されます。"
        case .offline:
            "変更内容はこの端末に保存されています。接続が戻ったら「iCloudと同期」で送れます。"
        case .needsReview:
            "両方の版を保ったまま保存しています。内容を確認して統合できます。"
        case .configurationError:
            "変更内容はこの端末に保存されています。iCloudアカウントまたは同期設定を確認してください。"
        case .syncPreparationError:
            "変更内容はこの端末に保存されています。同期準備を次の保存時に再試行します。"
        case .localSaveError:
            "この端末への保存を完了できませんでした。保存を再試行してください。"
        }
    }

    var showsProgress: Bool {
        self == .savingLocally || self == .syncing
    }

    var isWarning: Bool {
        switch self {
        case .needsReview, .configurationError, .syncPreparationError, .localSaveError:
            true
        case .savingLocally, .savedLocally, .syncing, .synced, .offline:
            false
        }
    }

    static func resolve(
        saveState: DocumentSaveState,
        syncState: DeviceSyncUIState,
        transferState: DeviceSyncTransferState,
        localDurability: DeviceSyncLocalDurabilityState
    ) -> Self {
        if saveState == .failed {
            return .localSaveError
        }
        if localDurability == .failed {
            return .localSaveError
        }
        if saveState != .saved || localDurability == .pending {
            return .savingLocally
        }
        if localDurability == .savedSyncPreparationFailed {
            return .syncPreparationError
        }
        if case .conflict = syncState {
            return .needsReview
        }
        if syncState == .needsReview {
            return .needsReview
        }
        if syncState == .blocked {
            return .configurationError
        }
        if syncState == .offlineLocal {
            return .offline
        }
        if transferState == .uploading ||
            syncState == .syncing || syncState == .forcing {
            return .syncing
        }
        if transferState == .upToDate, syncState.isConfigured {
            return .synced
        }
        return .savedLocally
    }
}

struct DeviceSyncEpisodeIdentity: Hashable {
    let documentSession: DocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
    let structureDigest: SyncWorkStructureDigest
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

/// bindingの非同期解決を、解決開始時の作品・話・Editor世代へ固定する。
/// `NovelDocument.id`はremote identityに使わない。
struct DeviceSyncLookupIdentity: Hashable {
    let documentSession: DocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
    let structureDigest: SyncWorkStructureDigest
}

/// D-061の作品同期preflightを、選択中の話ではなく作品sessionへ固定する。
///
/// 話が0件でも作品タイトル・人物・世界観などは同期対象なので、Episode由来の
/// lookupが作れないことを理由にwork journalの復旧を省略してはならない。
struct WorkSyncPreparationIdentity: Hashable {
    let documentSession: DocumentSessionToken
    let structureDigest: SyncWorkStructureDigest
}

struct DeviceSyncClient {
    let coordinator: EpisodeSyncCoordinator
    let sessionID: SyncEditSessionID
    let remoteAvailability: DeviceSyncRemoteAvailability

    var remoteSynchronizationAllowed: Bool {
        remoteAvailability == .available
    }
}

struct WorkSyncDocumentIdentity: Hashable {
    let documentSession: DocumentSessionToken
    let workID: SyncWorkID
    let localWorkingCopyID: LocalWorkingCopyID
}

struct WorkSyncClient {
    let coordinator: WorkSyncCoordinator
    let sessionID: SyncEditSessionID
    let remoteAvailability: DeviceSyncRemoteAvailability

    var remoteSynchronizationAllowed: Bool {
        remoteAvailability == .available
    }
}

struct NoteSyncClient {
    let coordinator: NoteSyncCoordinator
    let remoteAvailability: DeviceSyncRemoteAvailability

    var remoteSynchronizationAllowed: Bool {
        remoteAvailability == .available
    }
}

struct DeviceSyncClientKey: Hashable {
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct PendingDeviceSyncConflictResolution {
    let key: EpisodeSyncKey
    let conflict: EpisodeConflict
    let content: String
}
