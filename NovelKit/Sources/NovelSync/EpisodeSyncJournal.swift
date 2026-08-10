import Foundation

public enum EpisodeSyncJournalMode: String, Codable, Sendable {
    case tracking
    case forcedFork
}

public enum EpisodeSyncJournalError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case keyMismatch
    case revisionKeyMismatch
    case localHeadMissing
    case pendingChainBroken
    case tooManyPendingRevisions
    case sealedPublishMismatch
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

public struct EpisodeSyncJournalRecord: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    /// sealed batch（通常最大2）+ publish中にcoalesceされた次tail 1件。
    public static let maximumPendingRevisionCount = 3

    public let schemaVersion: Int
    public let key: EpisodeSyncKey
    public var branchID: SyncBranchID
    public var lastKnownRemoteHead: EpisodeRevision?
    public var localHead: EpisodeRevision
    public var pendingRevisions: [EpisodeRevision]
    public var sealedPublish: EpisodeSealedPublish?
    public var lease: EpisodeLease?
    public var conflict: EpisodeConflict?
    public var mode: EpisodeSyncJournalMode

    public init(
        key: EpisodeSyncKey,
        branchID: SyncBranchID,
        lastKnownRemoteHead: EpisodeRevision?,
        localHead: EpisodeRevision,
        pendingRevisions: [EpisodeRevision] = [],
        sealedPublish: EpisodeSealedPublish? = nil,
        lease: EpisodeLease? = nil,
        conflict: EpisodeConflict? = nil,
        mode: EpisodeSyncJournalMode = .tracking
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.key = key
        self.branchID = branchID
        self.lastKnownRemoteHead = lastKnownRemoteHead
        self.localHead = localHead
        self.pendingRevisions = pendingRevisions
        self.sealedPublish = sealedPublish
        self.lease = lease
        self.conflict = conflict
        self.mode = mode
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        key = try container.decode(EpisodeSyncKey.self, forKey: .key)
        branchID = try container.decode(SyncBranchID.self, forKey: .branchID)
        lastKnownRemoteHead = try container.decodeIfPresent(EpisodeRevision.self, forKey: .lastKnownRemoteHead)
        localHead = try container.decode(EpisodeRevision.self, forKey: .localHead)
        pendingRevisions = try container.decode([EpisodeRevision].self, forKey: .pendingRevisions)
        sealedPublish = try container.decodeIfPresent(EpisodeSealedPublish.self, forKey: .sealedPublish)
        lease = try container.decodeIfPresent(EpisodeLease.self, forKey: .lease)
        conflict = try container.decodeIfPresent(EpisodeConflict.self, forKey: .conflict)
        mode = try container.decode(EpisodeSyncJournalMode.self, forKey: .mode)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EpisodeSyncJournalError.unsupportedSchemaVersion(schemaVersion)
        }
        guard localHead.key == key,
              lastKnownRemoteHead.map({ $0.key == key }) ?? true,
              conflict.map({ $0.local.key == key }) ?? true,
              conflict.map({ $0.remote.key == key }) ?? true,
              conflict?.base.map({ $0.key == key }) ?? true else {
            throw EpisodeSyncJournalError.keyMismatch
        }
        for revision in pendingRevisions {
            try revision.validate()
            guard revision.key == key else { throw EpisodeSyncJournalError.revisionKeyMismatch }
        }
        guard pendingRevisions.count <= Self.maximumPendingRevisionCount else {
            throw EpisodeSyncJournalError.tooManyPendingRevisions
        }
        try localHead.validate()
        try lastKnownRemoteHead?.validate()
        try conflict?.base?.validate()
        try conflict?.local.validate()
        try conflict?.remote.validate()
        if let finalPending = pendingRevisions.last,
           finalPending.revisionID != localHead.revisionID {
            throw EpisodeSyncJournalError.localHeadMissing
        }
        for (index, revision) in pendingRevisions.enumerated() where index > 0 {
            guard revision.parentRevisionIDs.contains(pendingRevisions[index - 1].revisionID) else {
                throw EpisodeSyncJournalError.pendingChainBroken
            }
        }
        if let sealedPublish {
            let pendingIDs = Set(pendingRevisions.map(\.revisionID))
            guard !sealedPublish.revisionIDs.isEmpty,
                  sealedPublish.revisionIDs.count <= EpisodePublishRequest.maximumRevisionCount,
                  sealedPublish.revisionIDs.allSatisfy(pendingIDs.contains),
                  sealedPublish.revisionIDs.last == sealedPublish.candidateHeadRevisionID else {
                throw EpisodeSyncJournalError.sealedPublishMismatch
            }
        }
    }
}

public protocol EpisodeSyncJournal: Sendable {
    func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord?
    func save(_ record: EpisodeSyncJournalRecord) async throws
}
