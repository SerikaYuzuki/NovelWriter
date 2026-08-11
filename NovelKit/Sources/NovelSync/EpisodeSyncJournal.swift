import Foundation

public enum EpisodeSyncJournalMode: String, Codable, Sendable {
    case tracking
    case forcedFork
}

public enum EpisodeRemoteConfirmation: String, Codable, Sendable {
    case confirmed
    case unconfirmed
}

public enum EpisodeLocalEditIntent: String, Codable, Sendable {
    case observed
    case explicit
}

public enum EpisodeRemoteReconciliationStatus: String, Codable, Sendable {
    case idle
    case pending
    case offline
    case reviewRequired
}

public enum EpisodeSyncJournalError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case keyMismatch
    case revisionKeyMismatch
    case localHeadMissing
    case pendingChainBroken
    case tooManyPendingRevisions
    case sealedPublishMismatch
    case workingCopyMismatch
    case materializationMismatch
    case reviewDraftMismatch
    case unsafeRoot
    case invalidFile
}

public struct EpisodeSealedPublish: Hashable, Codable, Sendable {
    public let mutationID: SyncMutationID
    public let revisionIDs: [SyncRevisionID]
    public let candidateHeadRevisionID: SyncRevisionID
    public let expectedHeadRevisionID: SyncRevisionID?

    public init(
        mutationID: SyncMutationID,
        revisionIDs: [SyncRevisionID],
        candidateHeadRevisionID: SyncRevisionID,
        expectedHeadRevisionID: SyncRevisionID?
    ) {
        self.mutationID = mutationID
        self.revisionIDs = revisionIDs
        self.candidateHeadRevisionID = candidateHeadRevisionID
        self.expectedHeadRevisionID = expectedHeadRevisionID
    }
}

public struct EpisodeConflictResolutionRecovery: Hashable, Codable, Sendable {
    public let sourceLocalRevision: EpisodeRevision
    public let sourceRemoteRevision: EpisodeRevision
    public let chosenRevision: EpisodeRevision
    /// remote advance後に新しい解決を選び直した場合の、直前の確認済みchosen。
    /// 最新の再解決がremote ackされるまで1世代だけboundedに保持する。
    public let supersededChosenRevision: EpisodeRevision?

    public init(
        sourceLocalRevision: EpisodeRevision,
        sourceRemoteRevision: EpisodeRevision,
        chosenRevision: EpisodeRevision,
        supersededChosenRevision: EpisodeRevision? = nil
    ) {
        self.sourceLocalRevision = sourceLocalRevision
        self.sourceRemoteRevision = sourceRemoteRevision
        self.chosenRevision = chosenRevision
        self.supersededChosenRevision = supersededChosenRevision
    }
}

public struct EpisodeSyncJournalRecord: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case protocolVersion
        case key
        case localWorkingCopyID
        case replicaID
        case branchID
        case lastKnownRemoteHead
        case localHead
        case pendingRevisions
        case sealedPublish
        case lease
        case conflict
        case stagedConflictResolution
        case conflictResolutionRecovery
        case integrationReviewDraft
        case pendingMaterialization
        case remoteConfirmation
        case localEditIntent
        case reconciliationStatus
        case mode
    }

    private struct DecodedFacets {
        let reviewDraft: EpisodeIntegrationReviewDraft?
        let materialization: EpisodePendingMaterialization?
        let remoteConfirmation: EpisodeRemoteConfirmation
        let editIntent: EpisodeLocalEditIntent
        let reconciliationStatus: EpisodeRemoteReconciliationStatus
    }

    public static let currentSchemaVersion = 2
    /// sealed 2-parent merge（最大2件）+ coalesced working/integration tail。
    public static let maximumPendingRevisionCount = 4
    public static let maximumConflictPendingRevisionCount = 3

    public let schemaVersion: Int
    public let protocolVersion: Int
    public let key: EpisodeSyncKey
    /// schema v1 decode直後だけnilを許す。Coordinator.restoreがbinding由来IDを
    /// 最初のatomic saveで注入し、schema v2として保存する。
    public var localWorkingCopyID: LocalWorkingCopyID?
    public let replicaID: SyncReplicaID
    public var branchID: SyncBranchID
    public var lastKnownRemoteHead: EpisodeRevision?
    public var localHead: EpisodeRevision
    public var pendingRevisions: [EpisodeRevision]
    public var sealedPublish: EpisodeSealedPublish?
    public var lease: EpisodeLease?
    public var conflict: EpisodeConflict?
    /// authority claim前にjournalへ固定した、まだpublish queueへ入れていない採用revision。
    public var stagedConflictResolution: EpisodeRevision?
    /// publish後もpackage/native materializationのexact ackまで元の両本文と採用本文を保持する。
    public var conflictResolutionRecovery: EpisodeConflictResolutionRecovery?
    public var integrationReviewDraft: EpisodeIntegrationReviewDraft?
    public var pendingMaterialization: EpisodePendingMaterialization?
    public var remoteConfirmation: EpisodeRemoteConfirmation
    public var localEditIntent: EpisodeLocalEditIntent
    public var reconciliationStatus: EpisodeRemoteReconciliationStatus
    public var mode: EpisodeSyncJournalMode

    public init(
        key: EpisodeSyncKey,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID? = nil,
        branchID: SyncBranchID,
        lastKnownRemoteHead: EpisodeRevision?,
        localHead: EpisodeRevision,
        pendingRevisions: [EpisodeRevision] = [],
        sealedPublish: EpisodeSealedPublish? = nil,
        lease: EpisodeLease? = nil,
        conflict: EpisodeConflict? = nil,
        stagedConflictResolution: EpisodeRevision? = nil,
        conflictResolutionRecovery: EpisodeConflictResolutionRecovery? = nil,
        integrationReviewDraft: EpisodeIntegrationReviewDraft? = nil,
        pendingMaterialization: EpisodePendingMaterialization? = nil,
        remoteConfirmation: EpisodeRemoteConfirmation? = nil,
        localEditIntent: EpisodeLocalEditIntent? = nil,
        reconciliationStatus: EpisodeRemoteReconciliationStatus? = nil,
        mode: EpisodeSyncJournalMode = .tracking
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        protocolVersion = SyncWireProtocol.currentVersion
        self.key = key
        self.localWorkingCopyID = localWorkingCopyID
        self.replicaID = replicaID ?? localHead.authorReplicaID
        self.branchID = branchID
        self.lastKnownRemoteHead = lastKnownRemoteHead
        self.localHead = localHead
        self.pendingRevisions = pendingRevisions
        self.sealedPublish = sealedPublish
        self.lease = lease
        self.conflict = conflict
        self.stagedConflictResolution = stagedConflictResolution
        self.conflictResolutionRecovery = conflictResolutionRecovery
        self.integrationReviewDraft = integrationReviewDraft
            ?? Self.defaultReviewDraft(for: conflict)
        self.pendingMaterialization = pendingMaterialization
        self.remoteConfirmation = remoteConfirmation
            ?? Self.inferredRemoteConfirmation(
                localHead: localHead,
                lastKnownRemoteHead: lastKnownRemoteHead,
                pendingRevisions: pendingRevisions,
                conflict: conflict,
                pendingMaterialization: pendingMaterialization
            )
        self.localEditIntent = localEditIntent
            ?? (pendingRevisions.isEmpty && conflict == nil && pendingMaterialization == nil
                ? .observed
                : .explicit)
        self.reconciliationStatus = reconciliationStatus
            ?? (conflict != nil
                ? .reviewRequired
                : pendingRevisions.isEmpty && pendingMaterialization == nil ? .idle : .pending)
        self.mode = mode
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard storedSchemaVersion == 1 || storedSchemaVersion == Self.currentSchemaVersion else {
            throw EpisodeSyncJournalError.unsupportedSchemaVersion(storedSchemaVersion)
        }
        schemaVersion = Self.currentSchemaVersion
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? SyncWireProtocol.currentVersion
        key = try container.decode(EpisodeSyncKey.self, forKey: .key)
        branchID = try container.decode(SyncBranchID.self, forKey: .branchID)
        lastKnownRemoteHead = try container.decodeIfPresent(EpisodeRevision.self, forKey: .lastKnownRemoteHead)
        localHead = try container.decode(EpisodeRevision.self, forKey: .localHead)
        localWorkingCopyID = try Self.decodeWorkingCopyID(
            from: container,
            storedSchemaVersion: storedSchemaVersion
        )
        replicaID = try container.decodeIfPresent(SyncReplicaID.self, forKey: .replicaID)
            ?? localHead.authorReplicaID
        pendingRevisions = try container.decode([EpisodeRevision].self, forKey: .pendingRevisions)
        sealedPublish = try container.decodeIfPresent(EpisodeSealedPublish.self, forKey: .sealedPublish)
        lease = try container.decodeIfPresent(EpisodeLease.self, forKey: .lease)
        conflict = try container.decodeIfPresent(EpisodeConflict.self, forKey: .conflict)
        stagedConflictResolution = try container.decodeIfPresent(
            EpisodeRevision.self,
            forKey: .stagedConflictResolution
        )
        conflictResolutionRecovery = try container.decodeIfPresent(
            EpisodeConflictResolutionRecovery.self,
            forKey: .conflictResolutionRecovery
        )
        let facets = try Self.decodeFacets(
            from: container,
            localHead: localHead,
            lastKnownRemoteHead: lastKnownRemoteHead,
            pendingRevisions: pendingRevisions,
            conflict: conflict
        )
        integrationReviewDraft = facets.reviewDraft
        pendingMaterialization = facets.materialization
        remoteConfirmation = facets.remoteConfirmation
        localEditIntent = facets.editIntent
        reconciliationStatus = facets.reconciliationStatus
        mode = try container.decode(EpisodeSyncJournalMode.self, forKey: .mode)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(key, forKey: .key)
        guard let localWorkingCopyID else {
            throw EpisodeSyncJournalError.workingCopyMismatch
        }
        try container.encode(localWorkingCopyID, forKey: .localWorkingCopyID)
        try container.encode(replicaID, forKey: .replicaID)
        try container.encode(branchID, forKey: .branchID)
        try container.encodeIfPresent(lastKnownRemoteHead, forKey: .lastKnownRemoteHead)
        try container.encode(localHead, forKey: .localHead)
        try container.encode(pendingRevisions, forKey: .pendingRevisions)
        try container.encodeIfPresent(sealedPublish, forKey: .sealedPublish)
        try container.encodeIfPresent(lease, forKey: .lease)
        try container.encodeIfPresent(conflict, forKey: .conflict)
        try container.encodeIfPresent(stagedConflictResolution, forKey: .stagedConflictResolution)
        try container.encodeIfPresent(conflictResolutionRecovery, forKey: .conflictResolutionRecovery)
        try container.encodeIfPresent(integrationReviewDraft, forKey: .integrationReviewDraft)
        try container.encodeIfPresent(pendingMaterialization, forKey: .pendingMaterialization)
        try container.encode(remoteConfirmation, forKey: .remoteConfirmation)
        try container.encode(localEditIntent, forKey: .localEditIntent)
        try container.encode(reconciliationStatus, forKey: .reconciliationStatus)
        try container.encode(mode, forKey: .mode)
    }

    private static func decodeWorkingCopyID(
        from container: KeyedDecodingContainer<CodingKeys>,
        storedSchemaVersion: Int
    ) throws -> LocalWorkingCopyID? {
        if storedSchemaVersion == 1 {
            return try container.decodeIfPresent(
                LocalWorkingCopyID.self,
                forKey: .localWorkingCopyID
            )
        }
        return try container.decode(LocalWorkingCopyID.self, forKey: .localWorkingCopyID)
    }

    private static func decodeFacets(
        from container: KeyedDecodingContainer<CodingKeys>,
        localHead: EpisodeRevision,
        lastKnownRemoteHead: EpisodeRevision?,
        pendingRevisions: [EpisodeRevision],
        conflict: EpisodeConflict?
    ) throws -> DecodedFacets {
        let reviewDraft = try container.decodeIfPresent(
            EpisodeIntegrationReviewDraft.self,
            forKey: .integrationReviewDraft
        ) ?? defaultReviewDraft(for: conflict)
        let materialization = try container.decodeIfPresent(
            EpisodePendingMaterialization.self,
            forKey: .pendingMaterialization
        )
        let confirmation = try container.decodeIfPresent(
            EpisodeRemoteConfirmation.self,
            forKey: .remoteConfirmation
        ) ?? inferredRemoteConfirmation(
            localHead: localHead,
            lastKnownRemoteHead: lastKnownRemoteHead,
            pendingRevisions: pendingRevisions,
            conflict: conflict,
            pendingMaterialization: materialization
        )
        let intent = try container.decodeIfPresent(
            EpisodeLocalEditIntent.self,
            forKey: .localEditIntent
        ) ?? (pendingRevisions.isEmpty && conflict == nil && materialization == nil
            ? .observed
            : .explicit)
        let status = try container.decodeIfPresent(
            EpisodeRemoteReconciliationStatus.self,
            forKey: .reconciliationStatus
        ) ?? (conflict != nil
            ? .reviewRequired
            : pendingRevisions.isEmpty && materialization == nil ? .idle : .pending)
        return DecodedFacets(
            reviewDraft: reviewDraft,
            materialization: materialization,
            remoteConfirmation: confirmation,
            editIntent: intent,
            reconciliationStatus: status
        )
    }
}

public protocol EpisodeSyncJournal: Sendable {
    func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord?
    func save(_ record: EpisodeSyncJournalRecord) async throws
}
