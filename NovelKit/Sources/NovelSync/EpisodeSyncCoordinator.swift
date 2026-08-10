import Foundation

public struct EpisodeSyncContext: Hashable, Sendable {
    public let key: EpisodeSyncKey
    public let localHead: EpisodeRevision
    public let lastKnownRemoteHead: EpisodeRevision?
    public let lease: EpisodeLease?
    public let pendingRevisionCount: Int

    public init(
        key: EpisodeSyncKey,
        localHead: EpisodeRevision,
        lastKnownRemoteHead: EpisodeRevision?,
        lease: EpisodeLease?,
        pendingRevisionCount: Int
    ) {
        self.key = key
        self.localHead = localHead
        self.lastKnownRemoteHead = lastKnownRemoteHead
        self.lease = lease
        self.pendingRevisionCount = pendingRevisionCount
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
}

/// 話本文の同期状態機械。native editorのIME確定と`.novelpkg`保存はApp側が先に行い、
/// このactorへ渡すのは確定済み全文だけとする。
public actor EpisodeSyncCoordinator {
    public let key: EpisodeSyncKey
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

    public var authorityGrantAwaitingInstall: EpisodeAuthorityGrant? {
        pendingAuthorityGrant
    }

    public init(
        key: EpisodeSyncKey,
        replicaID: SyncReplicaID,
        sessionID: SyncEditSessionID,
        transport: any EpisodeSyncTransport,
        journal: any EpisodeSyncJournal
    ) {
        self.key = key
        self.replicaID = replicaID
        self.sessionID = sessionID
        self.transport = transport
        self.journal = journal
    }

    @discardableResult
    public func restore() async throws -> EpisodeSyncState {
        record = try await journal.load(for: key)
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
            branchID: branchID,
            lastKnownRemoteHead: nil,
            localHead: genesis,
            pendingRevisions: [genesis],
            mode: .tracking
        )
        try await persistAndUpdateState()
        _ = try await claimEditingAuthority(expiresAt: leaseExpiresAt)
        return try await synchronize()
    }
}
