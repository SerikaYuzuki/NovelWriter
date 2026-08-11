import Darwin
import Foundation
import NovelCore
import NovelSync

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

struct DeviceSyncSetupRuntime: Sendable {
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
}

enum DeviceSyncRemoteAvailability: Hashable, Sendable {
    case available
    case temporarilyOffline
    case configurationBlocked
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
            "変更内容をこの端末へ保存しています。入力はそのまま続けられます。"
        case .savedLocally:
            "変更内容はこの端末に保存されています。"
        case .syncing:
            "変更内容はこの端末に保存されています。iCloudへの反映を続けています。"
        case .synced:
            "変更内容はこの端末とiCloudの両方に保存されています。"
        case .offline:
            "変更内容はこの端末に保存されています。接続が戻ると自動で同期します。"
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

struct DeviceSyncClientKey: Hashable {
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct PendingDeviceSyncConflictResolution {
    let key: EpisodeSyncKey
    let conflict: EpisodeConflict
    let content: String
}
