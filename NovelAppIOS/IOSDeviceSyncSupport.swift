import Darwin
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
        self.now = now
        self.leaseDuration = leaseDuration
    }

    func leaseExpiration() -> Date {
        now().addingTimeInterval(leaseDuration)
    }
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
}

enum IOSDeviceSyncRemoteAvailability: Hashable, Sendable {
    case available
    case temporarilyOffline
    case configurationBlocked
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
            "本文はこの端末に保存されています。"
        case .syncing:
            "本文はこの端末に保存されています。iCloudへの反映を続けています。"
        case .synced:
            "本文はこの端末とiCloudの両方に保存されています。"
        case .offline:
            "本文はこの端末に保存されています。接続が戻ると自動で同期します。"
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
        if transferState == .uploading || transferState == .localPending ||
            syncState == .syncing || syncState == .forcing {
            return .syncing
        }
        if transferState == .upToDate, syncState.isConfigured {
            return .synced
        }
        return .savedLocally
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

struct IOSPendingDeviceSyncConflictResolution {
    let key: EpisodeSyncKey
    let conflict: EpisodeConflict
    let content: String
}
