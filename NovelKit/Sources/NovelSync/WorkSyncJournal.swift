// Custom deduplicating Codable and graph validation intentionally share one schema definition.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
import Foundation

public enum WorkSyncJournalError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedProtocolVersion(Int)
    case workMismatch
    case workingCopyMismatch
    case invalidRevisionGraph
    case tooManyRevisions
    case stagedRevisionMismatch
    case materializationMismatch
    case reviewMismatch
    case unsafeRoot
    case invalidFile
}

public enum WorkMaterializationKind: String, Codable, Sendable {
    case remoteBootstrap
    case remoteFastForward
    case automaticMerge
    case conflictResolution
}

public struct WorkPendingMaterialization: Hashable, Codable, Sendable {
    public let kind: WorkMaterializationKind
    public let sourceLocalRevisionID: SyncRevisionID
    public let revision: WorkRevision

    public init(
        kind: WorkMaterializationKind,
        sourceLocalRevisionID: SyncRevisionID,
        revision: WorkRevision
    ) {
        self.kind = kind
        self.sourceLocalRevisionID = sourceLocalRevisionID
        self.revision = revision
    }
}

public struct WorkConflictReview: Hashable, Codable, Sendable, Identifiable {
    public var id: String {
        "\(local.revisionID):\(remote.revisionID)"
    }

    public let base: WorkRevision?
    public let local: WorkRevision
    public let remote: WorkRevision
    public let proposedSnapshot: WorkSnapshot
    public let conflicts: [WorkFieldConflict]

    public init(
        base: WorkRevision?,
        local: WorkRevision,
        remote: WorkRevision,
        proposedSnapshot: WorkSnapshot,
        conflicts: [WorkFieldConflict]
    ) throws {
        self.base = base
        self.local = local
        self.remote = remote
        self.proposedSnapshot = proposedSnapshot
        self.conflicts = conflicts
        try validate()
    }

    public func validate() throws {
        guard !conflicts.isEmpty,
              conflicts.count <= WorkSyncJournalRecord.maximumConflictCount,
              base?.workID == local.workID || base == nil,
              remote.workID == local.workID,
              base?.snapshot.documentID == local.snapshot.documentID || base == nil,
              remote.snapshot.documentID == local.snapshot.documentID,
              proposedSnapshot.documentID == local.snapshot.documentID else {
            throw WorkSyncJournalError.reviewMismatch
        }
        // WorkRevision is immutable and validates canonical bytes/digest at its
        // public construction and decode boundaries. Revalidating multi-MiB
        // snapshots here would multiply journal save cost by every reference.
        try proposedSnapshot.validate()
        for conflict in conflicts {
            try conflict.validate()
        }
    }
}

public enum WorkConflictResolutionChoice: Sendable {
    case keepLocal
    case keepRemote
    case useProposed
    case custom(WorkSnapshot)
}

public struct WorkSealedPublish: Hashable, Codable, Sendable {
    public let mutationID: SyncMutationID
    public let revisionIDs: [SyncRevisionID]
    public let candidateHeadRevisionID: SyncRevisionID
    public let expectedHeadRevisionID: SyncRevisionID?
    public let expectedHeadSnapshotDigest: SyncContentDigest?

    public init(
        mutationID: SyncMutationID,
        revisionIDs: [SyncRevisionID],
        candidateHeadRevisionID: SyncRevisionID,
        expectedHeadRevisionID: SyncRevisionID?,
        expectedHeadSnapshotDigest: SyncContentDigest?
    ) {
        self.mutationID = mutationID
        self.revisionIDs = revisionIDs
        self.candidateHeadRevisionID = candidateHeadRevisionID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.expectedHeadSnapshotDigest = expectedHeadSnapshotDigest
    }
}

public enum WorkReconciliationStatus: String, Codable, Sendable {
    case pending
    case synchronized
    case offline
    case reviewRequired
    case materializationRequired
}

public struct WorkSyncJournalRecord: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case protocolVersion
        case workID
        case localWorkingCopyID
        case replicaID
        case branchID
        case revisionStore
        case lastKnownRemoteHeadRevisionID
        case localHeadRevisionID
        case outboxRevisionIDs
        case sealedPublish
        case stagedLocalRevisionID
        case pendingRemoteMaterialization
        case retainedLocalRecoveryRevisionID
        case conflictReview
        case reconciliationStatus
    }

    private struct StoredMaterialization: Hashable, Codable, Sendable {
        let kind: WorkMaterializationKind
        let sourceLocalRevisionID: SyncRevisionID
        let revisionID: SyncRevisionID
    }

    private struct StoredConflictReview: Hashable, Codable, Sendable {
        let baseRevisionID: SyncRevisionID?
        let localRevisionID: SyncRevisionID
        let remoteRevisionID: SyncRevisionID
        let proposedSnapshot: WorkSnapshot
        let conflicts: [WorkFieldConflict]
    }

    public static let currentSchemaVersion = 1
    /// 通常はlatest full snapshot 1件。2-parent mergeのatomic batch(2件)を送信中にも
    /// Editorを止めずlatest tailを1件保持するため、transient上限だけ3件とする。
    public static let maximumOutboxRevisionCount = 3
    /// remote base + sealed merge batch 2件 + latest tail + package前stage。
    public static let maximumStoredRevisionCount = 5
    public static let maximumConflictCount = 512

    public let schemaVersion: Int
    public let protocolVersion: Int
    public let workID: SyncWorkID
    public let localWorkingCopyID: LocalWorkingCopyID
    public let replicaID: SyncReplicaID
    public var branchID: SyncBranchID
    public var lastKnownRemoteHead: WorkRevision?
    public var localHead: WorkRevision
    public var outbox: [WorkRevision]
    public var sealedPublish: WorkSealedPublish?
    /// package commit前にdurable化し、confirmまではpublishしないlocal intent。
    public var stagedLocalRevision: WorkRevision?
    /// remote fast-forward／merge／choiceをpackageへmaterializeするまで保持する。
    public var pendingRemoteMaterialization: WorkPendingMaterialization?
    /// recovery choiceで選ばれなかったlocal full snapshotをremote ackまで1件だけ保持する。
    public var retainedLocalRecoveryRevision: WorkRevision?
    public var conflictReview: WorkConflictReview?
    public var reconciliationStatus: WorkReconciliationStatus

    public init(
        workID: SyncWorkID,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID,
        branchID: SyncBranchID,
        lastKnownRemoteHead: WorkRevision?,
        localHead: WorkRevision,
        outbox: [WorkRevision],
        sealedPublish: WorkSealedPublish? = nil,
        stagedLocalRevision: WorkRevision? = nil,
        pendingRemoteMaterialization: WorkPendingMaterialization? = nil,
        retainedLocalRecoveryRevision: WorkRevision? = nil,
        conflictReview: WorkConflictReview? = nil,
        reconciliationStatus: WorkReconciliationStatus = .pending
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        protocolVersion = WorkSyncWireProtocol.currentVersion
        self.workID = workID
        self.localWorkingCopyID = localWorkingCopyID
        self.replicaID = replicaID
        self.branchID = branchID
        self.lastKnownRemoteHead = lastKnownRemoteHead
        self.localHead = localHead
        self.outbox = outbox
        self.sealedPublish = sealedPublish
        self.stagedLocalRevision = stagedLocalRevision
        self.pendingRemoteMaterialization = pendingRemoteMaterialization
        self.retainedLocalRecoveryRevision = retainedLocalRecoveryRevision
        self.conflictReview = conflictReview
        self.reconciliationStatus = reconciliationStatus
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        localWorkingCopyID = try container.decode(LocalWorkingCopyID.self, forKey: .localWorkingCopyID)
        replicaID = try container.decode(SyncReplicaID.self, forKey: .replicaID)
        branchID = try container.decode(SyncBranchID.self, forKey: .branchID)
        let revisions = try container.decode([WorkRevision].self, forKey: .revisionStore)
        guard revisions.count <= Self.maximumStoredRevisionCount,
              Set(revisions.map(\.revisionID)).count == revisions.count else {
            throw WorkSyncJournalError.tooManyRevisions
        }
        let revisionMap = Dictionary(uniqueKeysWithValues: revisions.map { ($0.revisionID, $0) })
        func required(_ id: SyncRevisionID) throws -> WorkRevision {
            guard let revision = revisionMap[id] else {
                throw WorkSyncJournalError.invalidRevisionGraph
            }
            return revision
        }
        if let id = try container.decodeIfPresent(
            SyncRevisionID.self,
            forKey: .lastKnownRemoteHeadRevisionID
        ) {
            lastKnownRemoteHead = try required(id)
        } else {
            lastKnownRemoteHead = nil
        }
        localHead = try required(container.decode(SyncRevisionID.self, forKey: .localHeadRevisionID))
        outbox = try container.decode([SyncRevisionID].self, forKey: .outboxRevisionIDs).map(required)
        sealedPublish = try container.decodeIfPresent(WorkSealedPublish.self, forKey: .sealedPublish)
        if let id = try container.decodeIfPresent(SyncRevisionID.self, forKey: .stagedLocalRevisionID) {
            stagedLocalRevision = try required(id)
        } else {
            stagedLocalRevision = nil
        }
        if let stored = try container.decodeIfPresent(
            StoredMaterialization.self,
            forKey: .pendingRemoteMaterialization
        ) {
            pendingRemoteMaterialization = try WorkPendingMaterialization(
                kind: stored.kind,
                sourceLocalRevisionID: stored.sourceLocalRevisionID,
                revision: required(stored.revisionID)
            )
        } else {
            pendingRemoteMaterialization = nil
        }
        if let id = try container.decodeIfPresent(
            SyncRevisionID.self,
            forKey: .retainedLocalRecoveryRevisionID
        ) {
            retainedLocalRecoveryRevision = try required(id)
        } else {
            retainedLocalRecoveryRevision = nil
        }
        if let stored = try container.decodeIfPresent(
            StoredConflictReview.self,
            forKey: .conflictReview
        ) {
            conflictReview = try WorkConflictReview(
                base: stored.baseRevisionID.map(required),
                local: required(stored.localRevisionID),
                remote: required(stored.remoteRevisionID),
                proposedSnapshot: stored.proposedSnapshot,
                conflicts: stored.conflicts
            )
        } else {
            conflictReview = nil
        }
        reconciliationStatus = try container.decode(
            WorkReconciliationStatus.self,
            forKey: .reconciliationStatus
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var revisionsByID: [SyncRevisionID: WorkRevision] = [:]
        for revision in referencedRevisions() {
            if let existing = revisionsByID[revision.revisionID], existing != revision {
                throw WorkSyncJournalError.invalidRevisionGraph
            }
            revisionsByID[revision.revisionID] = revision
        }
        guard revisionsByID.count <= Self.maximumStoredRevisionCount else {
            throw WorkSyncJournalError.tooManyRevisions
        }
        let revisionStore = revisionsByID.values.sorted {
            $0.revisionID.rawValue.uuidString < $1.revisionID.rawValue.uuidString
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(WorkSyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(workID, forKey: .workID)
        try container.encode(localWorkingCopyID, forKey: .localWorkingCopyID)
        try container.encode(replicaID, forKey: .replicaID)
        try container.encode(branchID, forKey: .branchID)
        try container.encode(revisionStore, forKey: .revisionStore)
        try container.encodeIfPresent(
            lastKnownRemoteHead?.revisionID,
            forKey: .lastKnownRemoteHeadRevisionID
        )
        try container.encode(localHead.revisionID, forKey: .localHeadRevisionID)
        try container.encode(outbox.map(\.revisionID), forKey: .outboxRevisionIDs)
        try container.encodeIfPresent(sealedPublish, forKey: .sealedPublish)
        try container.encodeIfPresent(stagedLocalRevision?.revisionID, forKey: .stagedLocalRevisionID)
        if let pendingRemoteMaterialization {
            try container.encode(
                StoredMaterialization(
                    kind: pendingRemoteMaterialization.kind,
                    sourceLocalRevisionID: pendingRemoteMaterialization.sourceLocalRevisionID,
                    revisionID: pendingRemoteMaterialization.revision.revisionID
                ),
                forKey: .pendingRemoteMaterialization
            )
        }
        try container.encodeIfPresent(
            retainedLocalRecoveryRevision?.revisionID,
            forKey: .retainedLocalRecoveryRevisionID
        )
        if let conflictReview {
            try container.encode(
                StoredConflictReview(
                    baseRevisionID: conflictReview.base?.revisionID,
                    localRevisionID: conflictReview.local.revisionID,
                    remoteRevisionID: conflictReview.remote.revisionID,
                    proposedSnapshot: conflictReview.proposedSnapshot,
                    conflicts: conflictReview.conflicts
                ),
                forKey: .conflictReview
            )
        }
        try container.encode(reconciliationStatus, forKey: .reconciliationStatus)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkSyncJournalError.unsupportedSchemaVersion(schemaVersion)
        }
        guard protocolVersion == WorkSyncWireProtocol.currentVersion else {
            throw WorkSyncJournalError.unsupportedProtocolVersion(protocolVersion)
        }
        guard outbox.count <= Self.maximumOutboxRevisionCount else {
            throw WorkSyncJournalError.tooManyRevisions
        }
        let revisions = [
            lastKnownRemoteHead,
            localHead,
            stagedLocalRevision,
            pendingRemoteMaterialization?.revision,
            retainedLocalRecoveryRevision,
            conflictReview?.base,
            conflictReview?.local,
            conflictReview?.remote
        ].compactMap(\.self) + outbox
        guard revisions.allSatisfy({ $0.workID == workID }) else {
            throw WorkSyncJournalError.workMismatch
        }
        var revisionsByID: [SyncRevisionID: WorkRevision] = [:]
        for revision in revisions {
            if let existing = revisionsByID[revision.revisionID], existing != revision {
                throw WorkSyncJournalError.invalidRevisionGraph
            }
            revisionsByID[revision.revisionID] = revision
        }
        guard revisions.allSatisfy({ $0.snapshot.documentID == localHead.snapshot.documentID }),
              conflictReview?.proposedSnapshot.documentID == localHead.snapshot.documentID
              || conflictReview == nil else {
            throw WorkSnapshotError.documentIdentityMismatch
        }
        // Every WorkRevision has already crossed its validating initializer or
        // decoder. Journal validation is intentionally graph/reference-only so
        // the deduplicated table does not re-encode the same large snapshot for
        // each by-value reference during every atomic save.
        try validateOutbox()
        try validateStagedLocalRevision()
        try validatePendingMaterialization()
        try conflictReview?.validate()
        if let conflictReview {
            let validReviewStatus = reconciliationStatus == .reviewRequired
                || (stagedLocalRevision != nil && reconciliationStatus == .materializationRequired)
            guard conflictReview.local.revisionID == localHead.revisionID,
                  pendingRemoteMaterialization == nil,
                  validReviewStatus else {
                throw WorkSyncJournalError.reviewMismatch
            }
        }
        if reconciliationStatus == .materializationRequired,
           stagedLocalRevision == nil, pendingRemoteMaterialization == nil {
            throw WorkSyncJournalError.materializationMismatch
        }
        let uniqueRevisionCount = Set(referencedRevisions().map(\.revisionID)).count
        guard uniqueRevisionCount <= Self.maximumStoredRevisionCount else {
            throw WorkSyncJournalError.tooManyRevisions
        }
    }

    private func validateOutbox() throws {
        let ids = outbox.map(\.revisionID)
        guard Set(ids).count == ids.count else {
            throw WorkSyncJournalError.invalidRevisionGraph
        }
        if !outbox.isEmpty {
            guard outbox.last?.revisionID == localHead.revisionID else {
                throw WorkSyncJournalError.invalidRevisionGraph
            }
            let indexes = Dictionary(uniqueKeysWithValues: outbox.enumerated().map {
                ($0.element.revisionID, $0.offset)
            })
            for (index, revision) in outbox.enumerated() {
                guard revision.parentRevisionIDs.compactMap({ indexes[$0] }).allSatisfy({ $0 < index }) else {
                    throw WorkSyncJournalError.invalidRevisionGraph
                }
                if index > 0 {
                    let previousID = outbox[index - 1].revisionID
                    guard revision.parentRevisionIDs.contains(previousID) else {
                        throw WorkSyncJournalError.invalidRevisionGraph
                    }
                }
            }
        }
        guard let sealedPublish else { return }
        let expectedRevisionIDs: [SyncRevisionID] = if let expectedID = sealedPublish.expectedHeadRevisionID,
                                                       let expectedIndex = ids.firstIndex(of: expectedID) {
            Array(ids.suffix(from: ids.index(after: expectedIndex)))
        } else {
            Array(ids.prefix(sealedPublish.revisionIDs.count))
        }
        let expectedDigestMatches = if let expectedID = sealedPublish.expectedHeadRevisionID,
                                       let expectedDigest = sealedPublish.expectedHeadSnapshotDigest {
            outbox.first(where: { $0.revisionID == expectedID })?.snapshotDigest == expectedDigest
                || lastKnownRemoteHead.map {
                    $0.revisionID == expectedID && $0.snapshotDigest == expectedDigest
                } == true
        } else {
            sealedPublish.expectedHeadRevisionID == nil
                && sealedPublish.expectedHeadSnapshotDigest == nil
        }
        guard !sealedPublish.revisionIDs.isEmpty,
              sealedPublish.revisionIDs == expectedRevisionIDs,
              sealedPublish.revisionIDs.last == sealedPublish.candidateHeadRevisionID,
              expectedDigestMatches else {
            throw WorkSyncJournalError.invalidRevisionGraph
        }
    }

    private func validateStagedLocalRevision() throws {
        guard let stagedLocalRevision else { return }
        let allowedParents: Set<[SyncRevisionID]> = [
            [localHead.revisionID],
            lastKnownRemoteHead.map { [$0.revisionID] } ?? [],
            conflictReview?.base.map { [$0.revisionID] } ?? [],
            outbox.first.map { [$0.revisionID] } ?? [],
            outbox.first?.parentRevisionIDs ?? []
        ]
        guard stagedLocalRevision.revisionID != localHead.revisionID,
              stagedLocalRevision.parentRevisionIDs.count <= 1,
              allowedParents.contains(stagedLocalRevision.parentRevisionIDs) else {
            throw WorkSyncJournalError.stagedRevisionMismatch
        }
    }

    private func validatePendingMaterialization() throws {
        guard let pending = pendingRemoteMaterialization else { return }
        guard conflictReview == nil,
              pending.sourceLocalRevisionID == localHead.revisionID else {
            throw WorkSyncJournalError.materializationMismatch
        }
        if pending.kind == .remoteBootstrap {
            guard pending.revision.revisionID == localHead.revisionID,
                  outbox.isEmpty else {
                throw WorkSyncJournalError.materializationMismatch
            }
        } else if pending.revision.revisionID == localHead.revisionID {
            throw WorkSyncJournalError.materializationMismatch
        }
    }

    private func referencedRevisions() -> [WorkRevision] {
        [
            lastKnownRemoteHead,
            localHead,
            stagedLocalRevision,
            pendingRemoteMaterialization?.revision,
            retainedLocalRecoveryRevision,
            conflictReview?.base,
            conflictReview?.local,
            conflictReview?.remote
        ].compactMap(\.self) + outbox
    }
}

public protocol WorkSyncJournal: Sendable {
    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord?
    func save(_ record: WorkSyncJournalRecord) async throws
}
