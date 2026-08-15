import Foundation
import NovelCore
import NovelSync

enum IOSDeviceSyncLocalPersistenceError: Error {
    case editIntentUnavailable
    case invalidEditIntent
}

struct IOSDeviceSyncRuntime {
    let replicaID: SyncReplicaID
    let transport: any EpisodeSyncTransport
    /// D-061の作品全体同期。既存D-060 runtime/testは`nil`のまま動作する。
    let workTransport: (any WorkSyncTransport)?
    /// CloudKit/account確認を行わず、端末内bindingとwork journalだけを復元する入口。
    let localWorkBinding: (@Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> IOSDeviceSyncBindingResolution?)?
    let binding: @Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> IOSDeviceSyncBindingResolution?
    let remoteChangeSignals: AsyncStream<Void>?
    let mergeRecoveryStore: any IOSDeviceSyncMergeRecoveryStoring
    let editIntentStore: any IOSDeviceSyncEditIntentStoring
    let setup: IOSDeviceSyncSetupRuntime?
    /// iCloudを正とする作品棚。`nil`はlegacy/test runtimeだけ。
    let library: IOSDeviceSyncLibraryRuntime?
    /// D-071のentity同期。`nil`ならD-061 WorkSyncCoordinator経路を使う。
    let makeNoteSyncCoordinator: (@Sendable (SyncWorkID, LocalWorkingCopyID) async throws -> NoteSyncCoordinator)?
    let now: @Sendable () -> Date
    let leaseDuration: TimeInterval

    init(
        replicaID: SyncReplicaID,
        transport: any EpisodeSyncTransport,
        workTransport: (any WorkSyncTransport)? = nil,
        localWorkBinding: (@Sendable (
            IOSPrivateDocumentID,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> IOSDeviceSyncBindingResolution?)? = nil,
        binding: @escaping @Sendable (
            IOSPrivateDocumentID,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> IOSDeviceSyncBindingResolution?,
        remoteChangeSignals: AsyncStream<Void>? = nil,
        mergeRecoveryStore: any IOSDeviceSyncMergeRecoveryStoring = IOSInMemoryDeviceSyncMergeRecoveryStore(),
        editIntentStore: any IOSDeviceSyncEditIntentStoring = IOSInMemoryDeviceSyncEditIntentStore(),
        setup: IOSDeviceSyncSetupRuntime? = nil,
        library: IOSDeviceSyncLibraryRuntime? = nil,
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

enum IOSDeviceSyncLibraryConnection: Equatable, Sendable {
    case checking
    case available
    case offline
    case accountRequired
    case differentAccount
}

enum IOSDeviceSyncRemoteLibraryAvailability: Equatable, Sendable {
    case locallyBound
    case remoteOnly
    case remoteDownloadPending
    case publishPending
}

struct IOSDeviceSyncRemoteLibraryEntry: Equatable, Sendable, Identifiable {
    var id: SyncWorkID {
        work.workID
    }

    let work: SyncWorkLibraryEntry
    let availability: IOSDeviceSyncRemoteLibraryAvailability
}

struct IOSDeviceSyncRemoteLibrarySnapshot: Equatable, Sendable {
    let entries: [IOSDeviceSyncRemoteLibraryEntry]
    let connection: IOSDeviceSyncLibraryConnection
}

struct IOSDeviceSyncPreparedLibraryWork: Sendable {
    let entry: SyncWorkLibraryEntry
    let document: NovelDocument
    let packageSnapshot: WorkSnapshot
    let bind: @Sendable (WorkSnapshot) async throws -> Void
}

/// App層からCloudKit具象型とregistry実装を隠すcloud-library境界。
struct IOSDeviceSyncLibraryRuntime: Sendable {
    let loadLocalInventory: @Sendable () async throws -> IOSDeviceSyncLocalLibraryInventory
    let loadRemoteLibrary: @Sendable () async throws -> IOSDeviceSyncRemoteLibrarySnapshot
    let packageURL: @Sendable (SyncWorkID) async throws -> URL
    let workIDForPackageURL: @Sendable (URL) async throws -> SyncWorkID?
    let stagingPackageURL: @Sendable (SyncWorkID) async throws -> URL
    let validateStagingPackage: @Sendable (URL, SyncWorkID) async throws -> Void
    let installStagingPackage: @Sendable (URL, SyncWorkID) async throws -> URL
    let discardStagingPackage: @Sendable (URL, SyncWorkID) async throws -> Void
    let validateInstalledPackage: @Sendable (SyncWorkID) async throws -> Void
    let reserveForPublish: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let abortPublishReservation: @Sendable (SyncWorkID) async throws -> Void
    let confirmPublishPackage: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let beginRemoteOpen: @Sendable (SyncWorkLibraryEntry) async throws -> Void
    let attestRemotePackage: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation,
        SyncWorkLibraryEntry
    ) async throws -> Void
    let prepareRemoteOpen: @Sendable (
        SyncWorkLibraryEntry
    ) async throws -> IOSDeviceSyncPreparedLibraryWork
    let resumeRemoteOpen: @Sendable (
        SyncWorkID
    ) async throws -> IOSDeviceSyncPreparedLibraryWork
    let canResumeRemoteOpenOffline: @Sendable (SyncWorkID) async -> Bool
    let offlineResumableRemoteOpenWorkIDs: @Sendable () async -> [SyncWorkID]
    let hasCompletedRemoteOpenLocally: @Sendable (SyncWorkLibraryEntry) async -> Bool
    let localWorkNeedsReview: @Sendable (SyncWorkID, UUID) async throws -> Bool
    let markSynced: @Sendable (SyncWorkID, SyncWorkLibraryEntry) async throws -> Void
    let markNeedsReview: @Sendable (SyncWorkID) async throws -> Void
    let quarantineInstalledPackage: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let quarantineForAccount: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let restoreRemoteOpenPending: @Sendable (
        SyncWorkID,
        SyncWorkLibraryEntry
    ) async throws -> Void
    let markLegacyPackageRecovered: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let recordPackageMutation: @Sendable (
        SyncWorkID,
        IOSDeviceSyncLocalPackageAttestation
    ) async throws -> Void
    let hasLocalPublishAuthority: @Sendable (SyncWorkID, UUID) async -> Bool
    let publishNewWork: @Sendable (SyncWorkID, NovelDocument, URL) async throws -> Void
    let resumeInitialWorkPublication: @Sendable (
        SyncWorkID,
        NovelDocument,
        URL
    ) async throws -> Void
    let removeLocalWork: @Sendable (SyncWorkID) async throws -> Void
}

struct IOSDeviceSyncSetupRuntime: Sendable {
    let candidates: @Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor]
    let startNew: @Sendable (
        IOSPrivateDocumentID,
        SyncWorkDescriptor,
        [EpisodeID]
    ) async throws -> Void
    let bindExisting: @Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest,
        SyncWorkID,
        [EpisodeID]
    ) async throws -> Void
}

enum IOSDeviceSyncSetupState: Equatable {
    case idle
    case loading
    case candidates([SyncWorkDescriptor])
    case configured
    case unavailable(message: String)
}

struct IOSPendingDeviceSyncNewWork {
    let session: IOSDocumentSessionToken
    let structureDigest: SyncWorkStructureDigest
    let descriptor: SyncWorkDescriptor
}

enum IOSDeviceSyncTransferState: Hashable {
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

enum IOSDeviceSyncRemoteAvailability: Hashable, Sendable {
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

struct IOSDeviceSyncBindingResolution: Sendable {
    let binding: SyncWorkingCopyBinding
    /// `nil`はremote確認なしで端末内のexact bindingだけを復元した状態。
    let descriptor: SyncWorkDescriptor?
    let journal: any EpisodeSyncJournal
    /// D-061作品全体同期の端末内journal。D-060だけのbindingでは`nil`。
    let workJournal: (any WorkSyncJournal)?
    let allowedEpisodeIDs: Set<EpisodeID>
    let remoteAvailability: IOSDeviceSyncRemoteAvailability

    init(
        binding: SyncWorkingCopyBinding,
        descriptor: SyncWorkDescriptor?,
        journal: any EpisodeSyncJournal,
        workJournal: (any WorkSyncJournal)? = nil,
        allowedEpisodeIDs: Set<EpisodeID>,
        remoteAvailability: IOSDeviceSyncRemoteAvailability? = nil
    ) {
        self.binding = binding
        self.descriptor = descriptor
        self.journal = journal
        self.workJournal = workJournal
        self.allowedEpisodeIDs = allowedEpisodeIDs
        self.remoteAvailability = remoteAvailability ?? (descriptor == nil ? .temporarilyOffline : .available)
    }
}

enum IOSDeviceSyncUIState: Hashable {
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
        // D-060: remote propagation state never locks the local editor.
        true
    }

    var isConfigured: Bool {
        self != .unconfigured
    }
}

enum IOSDeviceSyncLocalDurabilityState: Hashable {
    case notApplicable
    case pending
    case saved
    case failed
}

enum IOSDeviceSyncEditorStatusKind: Hashable {
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
            "arrow.triangle.2.circlepath"
        case .savedLocally, .synced:
            "checkmark.circle"
        case .offline:
            "icloud.slash"
        case .needsReview:
            "exclamationmark.triangle"
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
            "この端末に保存済み、iCloudにも同期済み"
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
            "本文をこの端末へ保存しています。入力はそのまま続けられます。"
        case .savedLocally:
            "本文はこの端末に保存されています。iCloudへ送るには「iCloudと同期」を使います。"
        case .syncing:
            "本文はこの端末に保存されています。iCloudへの反映を続けています。"
        case .synced:
            "本文はこの端末とiCloudの両方に保存されています。"
        case .offline:
            "本文はこの端末に保存されています。接続が戻ったら「iCloudと同期」で送れます。"
        case .needsReview:
            "両方の本文を保ったまま保存しています。内容を確認して統合できます。"
        case .configurationError:
            "本文はこの端末に保存されています。iCloudアカウントまたは同期設定を確認してください。"
        case .syncPreparationError:
            "本文はこの端末に保存されています。同期準備を次の保存または再起動時に再試行します。"
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
        saveState: IOSSaveState,
        syncState: IOSDeviceSyncUIState,
        transferState: IOSDeviceSyncTransferState,
        localDurability: IOSDeviceSyncLocalDurabilityState
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

    static func resolveForCurrentWork(
        saveState: IOSSaveState,
        syncState: IOSDeviceSyncUIState,
        transferState: IOSDeviceSyncTransferState,
        localDurability: IOSDeviceSyncLocalDurabilityState,
        hasLocalRecoveryReview: Bool,
        isLocalRecoveryReviewReady: Bool,
        usesWholeWorkSync: Bool
    ) -> Self {
        let base = resolve(
            saveState: saveState,
            syncState: syncState,
            transferState: transferState,
            localDurability: localDurability
        )
        if hasLocalRecoveryReview, !isLocalRecoveryReviewReady {
            return base == .localSaveError ? .localSaveError : .savingLocally
        }
        if hasLocalRecoveryReview, saveState != .failed, base != .savingLocally {
            return .needsReview
        }
        if usesWholeWorkSync,
           saveState == .saved,
           localDurability == .failed {
            return .syncPreparationError
        }
        return base
    }
}

struct IOSDeviceSyncEpisodeIdentity: Hashable {
    let editingToken: IOSEpisodeEditingToken
    let structureDigest: SyncWorkStructureDigest
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct IOSDeviceSyncLookupIdentity: Hashable {
    let editingToken: IOSEpisodeEditingToken
    let structureDigest: SyncWorkStructureDigest
}

struct IOSDeviceSyncClient {
    let coordinator: EpisodeSyncCoordinator
    let sessionID: SyncEditSessionID
    let remoteAvailability: IOSDeviceSyncRemoteAvailability

    var remoteSynchronizationAllowed: Bool {
        remoteAvailability == .available
    }
}

struct IOSDeviceSyncClientKey: Hashable {
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct IOSWorkSyncLookupIdentity: Hashable {
    let documentSession: IOSDocumentSessionToken
    let sourceDocumentID: UUID
}

struct IOSWorkSyncIdentity: Hashable {
    let documentSession: IOSDocumentSessionToken
    let localWorkingCopyID: LocalWorkingCopyID
    let workID: SyncWorkID
}

struct IOSWorkSyncClient {
    let coordinator: WorkSyncCoordinator
    let remoteAvailability: IOSDeviceSyncRemoteAvailability

    var remoteSynchronizationAllowed: Bool {
        remoteAvailability == .available
    }
}

struct IOSNoteSyncClient {
    let coordinator: NoteSyncCoordinator
    let remoteAvailability: IOSDeviceSyncRemoteAvailability

    var remoteSynchronizationAllowed: Bool {
        remoteAvailability == .available
    }
}

struct IOSPendingDeviceSyncConflictResolution {
    let key: EpisodeSyncKey
    let conflict: EpisodeConflict
    let content: String
}
