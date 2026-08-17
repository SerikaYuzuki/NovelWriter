import Foundation
import NovelCore
import NovelSyncV2

public struct V2HistoryOccurrence: Hashable, Sendable {
    public let occurrenceID: UUID
    public let snapshotID: SnapshotID
    public let reason: String
    public let pinned: Bool
    public let localGeneration: Int64
    public let createdAt: Date

    public init(
        occurrenceID: UUID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        localGeneration: Int64,
        createdAt: Date
    ) {
        self.occurrenceID = occurrenceID
        self.snapshotID = snapshotID
        self.reason = reason
        self.pinned = pinned
        self.localGeneration = localGeneration
        self.createdAt = createdAt
    }
}

public struct V2HistoryPage: Hashable, Sendable {
    public let items: [V2HistoryOccurrence]
    public let nextCursor: String?

    public init(items: [V2HistoryOccurrence], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct V2RemoteHead: Hashable, Sendable {
    public static let maximumGeneration: Int64 = 9_007_199_254_740_991

    public let snapshotID: SnapshotID
    public let generation: Int64

    public init(snapshotID: SnapshotID, generation: Int64) throws {
        guard generation > 0, generation <= Self.maximumGeneration else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        self.snapshotID = snapshotID
        self.generation = generation
    }

    /// Conversion boundary for a head that already passed the application
    /// wire validator.
    public init(validatedSnapshotID snapshotID: SnapshotID, generation: Int64) {
        self.snapshotID = snapshotID
        self.generation = generation
    }
}

public struct V2RemoteSnapshotGraph: Sendable {
    public let inboxID: UUID
    public let workID: WorkID
    public let headSnapshotID: SnapshotID
    public let snapshots: [EncodedSnapshot]
    public let expectedCurrentSnapshotID: SnapshotID?
    public let expectedLocalGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?

    public init(
        inboxID: UUID = UUID(),
        workID: WorkID,
        headSnapshotID: SnapshotID,
        snapshots: [EncodedSnapshot],
        expectedCurrentSnapshotID: SnapshotID?,
        expectedLocalGeneration: Int64,
        expectedRemoteHead: V2RemoteHead? = nil
    ) {
        self.inboxID = inboxID
        self.workID = workID
        self.headSnapshotID = headSnapshotID
        self.snapshots = snapshots
        self.expectedCurrentSnapshotID = expectedCurrentSnapshotID
        self.expectedLocalGeneration = expectedLocalGeneration
        self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2RemoteSnapshot: Sendable {
    public let inboxID: UUID
    public let workID: WorkID
    public let encoded: EncodedSnapshot
    public let expectedCurrentSnapshotID: SnapshotID?
    public let expectedLocalGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?

    public init(
        inboxID: UUID = UUID(),
        workID: WorkID,
        encoded: EncodedSnapshot,
        expectedCurrentSnapshotID: SnapshotID?,
        expectedLocalGeneration: Int64,
        expectedRemoteHead: V2RemoteHead? = nil
    ) {
        self.inboxID = inboxID
        self.workID = workID
        self.encoded = encoded
        self.expectedCurrentSnapshotID = expectedCurrentSnapshotID
        self.expectedLocalGeneration = expectedLocalGeneration
        self.expectedRemoteHead = expectedRemoteHead
    }

    var graph: V2RemoteSnapshotGraph {
        V2RemoteSnapshotGraph(
            inboxID: inboxID,
            workID: workID,
            headSnapshotID: encoded.snapshotId,
            snapshots: [encoded],
            expectedCurrentSnapshotID: expectedCurrentSnapshotID,
            expectedLocalGeneration: expectedLocalGeneration,
            expectedRemoteHead: expectedRemoteHead
        )
    }
}

public struct V2ConflictCandidate: Hashable, Sendable {
    public let conflictID: UUID
    public let revision: Int64
    public let workID: WorkID
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
}

public struct V2ServerResolutionRequest: Hashable, Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let inboxID: UUID
    public let expectedRemoteHead: V2RemoteHead

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        sourceGeneration: Int64,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        inboxID: UUID,
        expectedRemoteHead: V2RemoteHead
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.sourceGeneration = sourceGeneration
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.inboxID = inboxID
        self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2DeviceResolutionRequest: Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let inboxID: UUID
    public let remoteHead: V2RemoteHead

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        sourceGeneration: Int64,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        inboxID: UUID,
        remoteHead: V2RemoteHead
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.sourceGeneration = sourceGeneration
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.inboxID = inboxID
        self.remoteHead = remoteHead
    }
}

public struct V2KeepBothPreparationRequest: Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let newWorkID: WorkID
    public let newDocumentID: DocumentID

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        sourceGeneration: Int64,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        newWorkID: WorkID,
        newDocumentID: DocumentID
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.sourceGeneration = sourceGeneration
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.newWorkID = newWorkID
        self.newDocumentID = newDocumentID
    }
}

public struct V2KeepBothReservation: Hashable, Sendable {
    public let reservationID: UUID
    public let sourceWorkID: WorkID
    public let newWorkID: WorkID
    public let newDocumentID: DocumentID
    public let newRootSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let expectedOriginalHead: V2RemoteHead
    public let state: String
}

public struct V2RestorePreparationRequest: Sendable {
    public let workID: WorkID
    public let selectedSnapshotID: SnapshotID
    public let expectedLocalGeneration: Int64

    public init(
        workID: WorkID,
        selectedSnapshotID: SnapshotID,
        expectedLocalGeneration: Int64
    ) {
        self.workID = workID
        self.selectedSnapshotID = selectedSnapshotID
        self.expectedLocalGeneration = expectedLocalGeneration
    }
}

public struct V2RestorePreparationResult: Sendable {
    public let restoreID: UUID?
    public let checkpoint: V2CheckpointResult
    public let expectedRemoteHead: V2RemoteHead?
}
