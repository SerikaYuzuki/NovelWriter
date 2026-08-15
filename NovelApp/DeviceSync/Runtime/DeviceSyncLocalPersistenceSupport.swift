import Foundation
import NovelCore
import NovelSync

struct DeviceSyncEditIntentMarker: Codable, Hashable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let workingCopyIdentity: String
    let documentID: UUID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
    let mutationSequence: UInt64
    let createdAt: Date
    let replicaID: SyncReplicaID
    let localWorkingCopyID: LocalWorkingCopyID?
    let workID: SyncWorkID?
    let baseContentDigest: SyncContentDigest?
    let acceptedPriorPackageDigests: [SyncContentDigest]?
    let content: String
    let contentDigest: SyncContentDigest
    /// Generic local-recovery reviewで明示採用済みのsource。
    /// Optional + additiveにし、旧markerは通常のedit intentとしてdecodeする。
    var resolvesPreservedSequences: [UInt64]?
}

struct DeviceSyncPackageCheckpoint: Codable, Hashable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let workingCopyIdentity: String
    let documentID: UUID
    let episodeID: EpisodeID
    let sequence: UInt64
    let contentDigest: SyncContentDigest
    let containsLocalEditIntent: Bool

    init(
        protocolVersion: Int,
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        sequence: UInt64,
        contentDigest: SyncContentDigest,
        containsLocalEditIntent: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.workingCopyIdentity = workingCopyIdentity
        self.documentID = documentID
        self.episodeID = episodeID
        self.sequence = sequence
        self.contentDigest = contentDigest
        self.containsLocalEditIntent = containsLocalEditIntent
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case workingCopyIdentity
        case documentID
        case episodeID
        case sequence
        case contentDigest
        case containsLocalEditIntent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        workingCopyIdentity = try container.decode(String.self, forKey: .workingCopyIdentity)
        documentID = try container.decode(UUID.self, forKey: .documentID)
        episodeID = try container.decode(EpisodeID.self, forKey: .episodeID)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        contentDigest = try container.decode(SyncContentDigest.self, forKey: .contentDigest)
        containsLocalEditIntent = try container.decodeIfPresent(
            Bool.self,
            forKey: .containsLocalEditIntent
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(workingCopyIdentity, forKey: .workingCopyIdentity)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(episodeID, forKey: .episodeID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(containsLocalEditIntent, forKey: .containsLocalEditIntent)
    }

    func acknowledgingLocalEditIntent() -> Self {
        Self(
            protocolVersion: protocolVersion,
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            sequence: sequence,
            contentDigest: contentDigest,
            containsLocalEditIntent: false
        )
    }
}

struct DeviceSyncLocalMutationScope: Hashable, Sendable {
    let workingCopyIdentity: String
    let documentID: UUID
    let episodeID: EpisodeID
}

struct DeviceSyncLocalMutation: Hashable, Sendable {
    let sequence: UInt64
    let containsLocalEditIntent: Bool
}

struct DeviceSyncLocalRecoveryReview: Hashable, Sendable {
    let packageContent: String
    let preservedMarkers: [DeviceSyncEditIntentMarker]
}

enum DeviceSyncLocalRecoveryChoice: Hashable, Sendable {
    case current
    case packageSnapshot
    case preserved(DeviceSyncEditIntentMarker)
    case manual(String)

    func content(current: String, review: DeviceSyncLocalRecoveryReview) -> String {
        switch self {
        case .current:
            current
        case .packageSnapshot:
            review.packageContent
        case let .preserved(marker):
            marker.content
        case let .manual(content):
            content
        }
    }
}

struct DeviceSyncLocalPersistenceSnapshot: Hashable, Sendable {
    let marker: DeviceSyncEditIntentMarker?
    let preservedMarkers: [DeviceSyncEditIntentMarker]
    let committedPackage: DeviceSyncPackageCheckpoint?
    let preparedPackage: DeviceSyncPackageCheckpoint?

    init(
        marker: DeviceSyncEditIntentMarker?,
        preservedMarkers: [DeviceSyncEditIntentMarker] = [],
        committedPackage: DeviceSyncPackageCheckpoint?,
        preparedPackage: DeviceSyncPackageCheckpoint?
    ) {
        self.marker = marker
        self.preservedMarkers = preservedMarkers
        self.committedPackage = committedPackage
        self.preparedPackage = preparedPackage
    }

    var highestSequence: UInt64 {
        [
            marker?.mutationSequence,
            preservedMarkers.map(\.mutationSequence).max(),
            committedPackage?.sequence,
            preparedPackage?.sequence
        ].compactMap(\.self).max() ?? 0
    }
}

protocol DeviceSyncEditIntentStoring: Sendable {
    func save(_ marker: DeviceSyncEditIntentMarker) async throws
    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [DeviceSyncEditIntentMarker]
    func remove(_ marker: DeviceSyncEditIntentMarker) async throws
    func save(
        _ marker: DeviceSyncEditIntentMarker,
        baselinePackageDigest: SyncContentDigest
    ) async throws -> DeviceSyncEditIntentMarker
    func preparePackageSave(_ checkpoint: DeviceSyncPackageCheckpoint) async throws
    func commitPackageSave(_ checkpoint: DeviceSyncPackageCheckpoint) async throws
    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> DeviceSyncLocalPersistenceSnapshot
    func reconcilePreparedPackage(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        actualContentDigest: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot
    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence: UInt64,
        contentDigest: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot
    func preserveForReview(_ marker: DeviceSyncEditIntentMarker) async throws
    func removePreservedForReview(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        expected: [DeviceSyncEditIntentMarker],
        expectedResolvingMarker: DeviceSyncEditIntentMarker
    ) async throws -> DeviceSyncLocalPersistenceSnapshot
}

extension DeviceSyncEditIntentStoring {
    func save(
        _ marker: DeviceSyncEditIntentMarker,
        baselinePackageDigest _: SyncContentDigest
    ) async throws -> DeviceSyncEditIntentMarker {
        try await save(marker)
        return marker
    }

    func preparePackageSave(_: DeviceSyncPackageCheckpoint) async throws {}

    func commitPackageSave(_: DeviceSyncPackageCheckpoint) async throws {}

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        let marker = try await load(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        ).max { $0.mutationSequence < $1.mutationSequence }
        return DeviceSyncLocalPersistenceSnapshot(
            marker: marker,
            preservedMarkers: [],
            committedPackage: nil,
            preparedPackage: nil
        )
    }

    func reconcilePreparedPackage(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        actualContentDigest _: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        try await loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence _: UInt64,
        contentDigest _: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        try await loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func preserveForReview(_: DeviceSyncEditIntentMarker) async throws {
        throw DeviceSyncLocalPersistenceError.editIntentUnavailable
    }

    func removePreservedForReview(
        workingCopyIdentity _: String,
        documentID _: UUID,
        episodeID _: EpisodeID,
        expected _: [DeviceSyncEditIntentMarker],
        expectedResolvingMarker _: DeviceSyncEditIntentMarker
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        throw DeviceSyncLocalPersistenceError.editIntentUnavailable
    }
}
