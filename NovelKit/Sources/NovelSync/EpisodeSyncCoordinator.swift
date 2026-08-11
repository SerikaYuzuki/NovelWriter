import Foundation

public struct EpisodeSyncContext: Hashable, Sendable {
    public let key: EpisodeSyncKey
    public let localWorkingCopyID: LocalWorkingCopyID
    public let branchID: SyncBranchID
    public let localHead: EpisodeRevision
    public let lastKnownRemoteHead: EpisodeRevision?
    public let lease: EpisodeLease?
    public let pendingRevisionCount: Int
    public let remoteConfirmation: EpisodeRemoteConfirmation
    public let pendingMaterialization: EpisodePendingMaterialization?
    public let hasExplicitLocalChanges: Bool
    public let reconciliationStatus: EpisodeRemoteReconciliationStatus

    public init(
        key: EpisodeSyncKey,
        localWorkingCopyID: LocalWorkingCopyID,
        branchID: SyncBranchID,
        localHead: EpisodeRevision,
        lastKnownRemoteHead: EpisodeRevision?,
        lease: EpisodeLease?,
        pendingRevisionCount: Int,
        remoteConfirmation: EpisodeRemoteConfirmation,
        pendingMaterialization: EpisodePendingMaterialization?,
        hasExplicitLocalChanges: Bool,
        reconciliationStatus: EpisodeRemoteReconciliationStatus
    ) {
        self.key = key
        self.localWorkingCopyID = localWorkingCopyID
        self.branchID = branchID
        self.localHead = localHead
        self.lastKnownRemoteHead = lastKnownRemoteHead
        self.lease = lease
        self.pendingRevisionCount = pendingRevisionCount
        self.remoteConfirmation = remoteConfirmation
        self.pendingMaterialization = pendingMaterialization
        self.hasExplicitLocalChanges = hasExplicitLocalChanges
        self.reconciliationStatus = reconciliationStatus
    }
}

/// `recordLocalEdit`が返った時点で、このrevisionはpackage外journalへ保存済み。
public struct EpisodeLocalEditReceipt: Hashable, Sendable {
    public let localWorkingCopyID: LocalWorkingCopyID
    public let revisionID: SyncRevisionID
    public let contentDigest: SyncContentDigest
    public let state: EpisodeSyncState

    public init(
        localWorkingCopyID: LocalWorkingCopyID,
        revisionID: SyncRevisionID,
        contentDigest: SyncContentDigest,
        state: EpisodeSyncState
    ) {
        self.localWorkingCopyID = localWorkingCopyID
        self.revisionID = revisionID
        self.contentDigest = contentDigest
        self.state = state
    }
}

public enum EpisodeSyncState: Hashable, Sendable {
    case unlinked
    /// journalのleaseはfresh processではauthorityとして扱わず、remote再検証までread-only。
    case restoredUnverified(EpisodeSyncContext)
    case upToDate(EpisodeSyncContext)
    case localChanges(EpisodeSyncContext)
    case offlineFork(EpisodeSyncContext)
    case synchronizing(EpisodeSyncContext)
    case authorityGrantedAwaitingInstall(EpisodeSyncContext, EpisodeAuthorityGrant)
    case readOnly(EpisodeSyncContext, heldBy: EpisodeLease)
    case authorityLost(EpisodeSyncContext, current: EpisodeRemoteSnapshot?)
    case remoteUpdateAvailable(EpisodeSyncContext, remote: EpisodeRevision)
    case conflicted(EpisodeSyncContext, EpisodeConflict)
}

public enum EpisodeFenceObservation: Hashable, Sendable {
    case authorityValid(EpisodeRemoteSnapshot)
    case remoteAdvanced(EpisodeRemoteSnapshot)
    case authorityLost(EpisodeRemoteSnapshot)

    public var remoteSnapshot: EpisodeRemoteSnapshot? {
        switch self {
        case let .authorityValid(snapshot),
             let .remoteAdvanced(snapshot),
             let .authorityLost(snapshot):
            snapshot
        }
    }
}

public enum EpisodeSyncCoordinatorError: Error, Equatable, Sendable {
    case notLinked
    case noRemoteHead
    case noEditingAuthority
    case noConflict
    case malformedRemoteSnapshot
    case authorityGrantNotPending
    case installedDigestMismatch
    case leaseClaimRejected
    case authorityGrantSuperseded
    case fenceObservationNotPending
    case remoteObservationSuperseded
    case unresolvedConflict
    case conflictSuperseded
    case materializationNotPending
}

/// 話本文の同期状態機械。native editorのIME確定と`.novelpkg`保存はApp側が先に行い、
/// このactorへ渡すのは確定済み全文だけとする。
public actor EpisodeSyncCoordinator {
    public let key: EpisodeSyncKey
    public let localWorkingCopyID: LocalWorkingCopyID
    public let replicaID: SyncReplicaID
    public let sessionID: SyncEditSessionID

    public internal(set) var state: EpisodeSyncState = .unlinked

    let transport: any EpisodeSyncTransport
    let journal: any EpisodeSyncJournal
    var record: EpisodeSyncJournalRecord?
    var pendingAuthorityGrant: EpisodeAuthorityGrant?
    var pendingFenceObservation: EpisodeFenceObservation?
    var authorityVerifiedInProcess = false
    var restoredAuthorityRequiresClaim = false
    /// Remote snapshot/controlを読む操作はactorの`await`再入をまたいでFIFOに直列化する。
    /// `recordLocalContent`はこのlaneを取得せず、network待機中も新しい本文を
    /// durable tailとして記録できる。
    var isRemoteControlOperationRunning = false
    var remoteControlOperationWaiters: [CheckedContinuation<Void, Never>] = []
    /// native callback由来のjournal書込みをFIFOにし、actor再入で古い本文が後勝ちしない。
    var isLocalJournalOperationRunning = false
    var localJournalOperationWaiters: [CheckedContinuation<Void, Never>] = []

    public var authorityGrantAwaitingInstall: EpisodeAuthorityGrant? {
        pendingAuthorityGrant
    }

    public var integrationAwaitingMaterialization: EpisodePendingMaterialization? {
        record?.pendingMaterialization
    }

    public var integrationReviewDraft: EpisodeIntegrationReviewDraft? {
        record?.integrationReviewDraft
    }

    public var conflictResolutionRecovery: EpisodeConflictResolutionRecovery? {
        record?.conflictResolutionRecovery
    }

    public var stagedConflictResolution: EpisodeRevision? {
        record?.stagedConflictResolution
    }

    public var conflictChoiceAwaitingMaterialization: EpisodeConflictResolutionMaterialization? {
        guard let conflict = record?.conflict,
              let chosen = record?.stagedConflictResolution else { return nil }
        return conflictResolutionMaterialization(conflict: conflict, chosen: chosen)
    }

    public init(
        key: EpisodeSyncKey,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID,
        sessionID: SyncEditSessionID,
        transport: any EpisodeSyncTransport,
        journal: any EpisodeSyncJournal
    ) {
        self.key = key
        self.localWorkingCopyID = localWorkingCopyID
        self.replicaID = replicaID
        self.sessionID = sessionID
        self.transport = transport
        self.journal = journal
    }

    @discardableResult
    public func restore() async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        record = try await journal.load(for: key)
        if var restored = record, restored.localWorkingCopyID == nil {
            restored.localWorkingCopyID = localWorkingCopyID
            record = restored
            try await journal.save(restored)
        }
        guard record?.localWorkingCopyID == localWorkingCopyID || record == nil else {
            throw EpisodeSyncJournalError.workingCopyMismatch
        }
        authorityVerifiedInProcess = false
        restoredAuthorityRequiresClaim = record != nil
        state = record.map { .restoredUnverified(context(for: $0)) } ?? .unlinked
        return state
    }

    /// remote workへ明示linkする。`SyncWorkID`は呼び出し側が選択済みの値を使う。
    @discardableResult
    public func link(
        localContent: String,
        createdAt: Date,
        leaseExpiresAt: Date
    ) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await linkSerially(
            localContent: localContent,
            createdAt: createdAt,
            leaseExpiresAt: leaseExpiresAt
        )
    }

    func linkSerially(
        localContent: String,
        createdAt: Date,
        leaseExpiresAt: Date
    ) async throws -> EpisodeSyncState {
        restoredAuthorityRequiresClaim = false
        let snapshot = try await transport.fetchSnapshot(for: key)
        let branchID = SyncBranchID()

        if let remoteHead = snapshot.head {
            record = try makeInitialLinkedRecord(
                localContent: localContent,
                remoteHead: remoteHead,
                snapshot: snapshot,
                branchID: branchID,
                createdAt: createdAt
            )
            try await persistAndUpdateState()
            return state
        }

        let genesis = try makeRevision(
            content: localContent,
            parents: [],
            branchID: branchID,
            createdAt: createdAt
        )
        record = try EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: nil,
            localHead: genesis,
            pendingRevisions: [genesis],
            mode: .tracking
        )
        try await persistAndUpdateState()
        _ = try await claimEditingAuthoritySerially(expiresAt: leaseExpiresAt)
        return try await synchronizeSerially()
    }

    func acquireRemoteControlOperation() async {
        guard isRemoteControlOperationRunning else {
            isRemoteControlOperationRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            remoteControlOperationWaiters.append(continuation)
        }
    }

    func releaseRemoteControlOperation() {
        guard !remoteControlOperationWaiters.isEmpty else {
            isRemoteControlOperationRunning = false
            return
        }
        remoteControlOperationWaiters.removeFirst().resume()
    }

    func acquireLocalJournalOperation() async {
        guard !isLocalJournalOperationRunning else {
            await withCheckedContinuation { continuation in
                localJournalOperationWaiters.append(continuation)
            }
            return
        }
        isLocalJournalOperationRunning = true
    }

    func releaseLocalJournalOperation() {
        guard !localJournalOperationWaiters.isEmpty else {
            isLocalJournalOperationRunning = false
            return
        }
        localJournalOperationWaiters.removeFirst().resume()
    }
}
