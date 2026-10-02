import Foundation
import NovelCore
import NovelSyncV2

/// Internal diagnostic/test access remains actor-isolated. Implementations live
/// in repositories, so callers cannot send a connection across actor boundaries.
extension LocalSyncV2Store {
    func insertHistory(
        workID: WorkID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        generation: Int64
    ) throws {
        try workRepository.insertHistory(
            workID: workID,
            snapshotID: snapshotID,
            reason: reason,
            pinned: pinned,
            generation: generation
        )
    }

    func inboxState(inboxID: UUID, binding: V2AccountBinding) throws -> String {
        try inboxRepository.inboxState(inboxID: inboxID, binding: binding)
    }

    func inboxExists(inboxID: UUID) throws -> Bool {
        try inboxRepository.inboxExists(inboxID: inboxID)
    }

    func loadEncoded(workID: WorkID, snapshotID: SnapshotID) throws -> EncodedSnapshot {
        try workRepository.loadEncoded(workID: workID, snapshotID: snapshotID)
    }

    func conflictInbox(_ conflict: V2ConflictCandidate) throws -> UUID {
        try conflictRepository.conflictInbox(conflict)
    }

    func acknowledgedHead(workID: WorkID) throws -> V2RemoteHead? {
        try conflictRepository.acknowledgedHead(workID: workID)
    }

    func graphHead(
        _ graph: V2RemoteSnapshotGraph,
        containsAncestor snapshotID: SnapshotID
    ) throws -> Bool {
        try conflictRepository.graphHead(graph, containsAncestor: snapshotID)
    }

    func publishBaseHead(workID: WorkID, snapshotID: SnapshotID) throws -> V2RemoteHead? {
        try workRepository.publishBaseHead(workID: workID, snapshotID: snapshotID)
    }

    func validateConflictBase(
        _ baseSnapshotID: SnapshotID?,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        workID: WorkID,
        graph: V2RemoteSnapshotGraph
    ) throws {
        try conflictRepository.validateConflictBase(
            baseSnapshotID,
            localSnapshotID: localSnapshotID,
            remoteSnapshotID: remoteSnapshotID,
            workID: workID,
            graph: graph
        )
    }

    func insertIntent(
        intentID: UUID,
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64,
        kind: String,
        scope: V2LocalWorkScope
    ) throws {
        try outboxRepository.insertIntent(.init(
            intentID: intentID,
            workID: workID,
            snapshotID: snapshotID,
            generation: generation,
            kind: kind,
            scope: scope
        ))
    }

    func insertValidatedEncoded(
        _ encoded: EncodedSnapshot,
        workID: WorkID,
        attestExistingObjects: Bool = true,
        verifiedRemote: Bool = false
    ) throws {
        try workRepository.insertValidatedEncoded(
            encoded,
            workID: workID,
            attestExistingObjects: attestExistingObjects,
            verifiedRemote: verifiedRemote
        )
    }

    func loadInboxGraph(
        inboxID: UUID,
        binding: V2AccountBinding
    ) throws -> V2RemoteSnapshotGraph {
        try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
    }

    func validateAcyclic(_ parents: [SnapshotID: [SnapshotID]]) throws {
        try inboxRepository.validateAcyclic(parents)
    }
}

extension LocalSyncV2Store {
    func decodeAcknowledgement(
        _ acknowledgement: V2CommandAcknowledgement,
        record: V2SealedCommandRecord
    ) throws -> DecodedCommandAcknowledgement {
        try outboxRepository.decodeAcknowledgement(acknowledgement, record: record)
    }
}
