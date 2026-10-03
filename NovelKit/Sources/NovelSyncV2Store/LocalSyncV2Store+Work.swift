import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Membership lookup only. Opening a document and loading immutable transfer
    /// bytes remain the validation boundaries for the manuscript itself.
    func workSummary(workID: WorkID, scope: V2LocalWorkScope) throws -> V2WorkSummary {
        try workRepository.workSummary(workID: workID, scope: scope)
    }

    /// Only bootstrap and quarantined records affect the planner's guards.
    /// Historical completed object requests are read for their exact occurrence
    /// below, avoiding allocations for accumulated completed transfer history.
    func planningGuardCommands(
        scope: V2LocalWorkScope,
        workID: WorkID
    ) throws -> [V2SealedCommandRecord] {
        try outboxRepository.planningGuardCommands(scope: scope, workID: workID)
    }

    /// Preserve row order and the complete binding/source identity. Upload
    /// capabilities from another generation must never satisfy this transfer.
    func completedTransferCommands(
        scope: V2LocalWorkScope,
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64
    ) throws -> [V2SealedCommandRecord] {
        try outboxRepository.completedTransferCommands(
            scope: scope,
            workID: workID,
            snapshotID: snapshotID,
            generation: generation
        )
    }
}

// Local-only mirror for the opaque remainder of an imported `.novelpkg`.
// Resource rows are intentionally not reachable from SnapshotCodec or the
// remote command planner: they preserve package fidelity without changing
// Snapshot identity.

public extension LocalSyncV2Store {
    func hasUnpromotedLeaf(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        try workRepository.hasUnpromotedLeaf(workID: workID, scope: scope)
    }

    /// Launch/foreground recovery is scoped to the attested account only.
    func promoteUnpromotedLeaves(scope: V2LocalWorkScope) throws {
        for work in try workRepository.listWorks(scope: scope)
            where try deletionRepository.workDeletion(workID: work.workID) == nil {
            try promoteCurrentLeaf(workID: work.workID, scope: scope)
        }
    }

    /// Promote durable bytes only. This never captures or installs editor text.
    @discardableResult
    func promoteCurrentLeaf(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        try inCheckpointNeutralTransaction {
            try workRepository.promoteCurrentLeafTransaction(workID: workID, scope: scope)
        }
    }
}

public extension LocalSyncV2Store {
    /// Content identity is separate from the latest observed (possibly newer) head.
    func isAcknowledgedContent(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> Bool {
        try workRepository.isAcknowledgedContent(workID: workID, snapshotID: snapshotID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    func isBoundary(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> Bool {
        try inboxRepository.isBoundary(workID: workID, snapshotID: snapshotID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    func historyIsIncomplete(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        try inboxRepository.historyIsIncomplete(workID: workID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    /// A verified Inbox can supply bytes while newer local edits postpone
    /// adoption. Its parents must still be traversed; it is not a committed anchor.
    func verifiedInboxSnapshot(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> EncodedSnapshot? {
        try workRepository.verifiedInboxSnapshot(workID: workID, snapshotID: snapshotID, scope: scope)
    }

    /// Only committed snapshots in this exact work/account scope may anchor a
    /// remote graph. Staged inbox rows and other accounts are not cache hits.
    func committedSnapshot(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> EncodedSnapshot? {
        try workRepository.committedSnapshot(workID: workID, snapshotID: snapshotID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    /// Returns the exact current manifest/object bytes and the intent that the
    /// worker is allowed to replicate.  No JSON decode/re-encode happens here.
    func immutableTransferView(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ImmutableTransferView? {
        try workRepository.immutableTransferView(workID: workID, scope: scope)
    }

    /// Selects the first unregistered dependency in parent-first order. The
    /// checkpoint intent remains unchanged; only object/registration commands
    /// use this historical snapshot's real local occurrence as their source.
    func nextSnapshotTransferView(
        for target: V2ImmutableTransferView,
        scope: V2LocalWorkScope
    ) throws -> V2ImmutableTransferView? {
        try workRepository.nextSnapshotTransferView(for: target, scope: scope)
    }

    func registeredSnapshotIDs(workID: WorkID, binding: V2AccountBinding) throws -> Set<SnapshotID> {
        try workRepository.registeredSnapshotIDs(workID: workID, binding: binding)
    }

    /// Evidence is scoped to the complete binding. Local bytes alone never
    /// prove availability; registered closure or a verified receipt does.
    func knownRemoteObjectIDs(workID: WorkID, scope: V2LocalWorkScope) throws -> Set<ObjectID> {
        try workRepository.knownRemoteObjectIDs(workID: workID, scope: scope)
    }

    /// Incremental evidence for one durable acknowledgement. Never scans a
    /// work's history. Upload acknowledgement alone is not object availability.
    func acknowledgedRemoteObjectIDs(
        commandID: UUID, verifiedInboxID: UUID? = nil, scope: V2LocalWorkScope
    ) throws -> Set<ObjectID> {
        try workRepository.acknowledgedRemoteObjectIDs(
            commandID: commandID,
            verifiedInboxID: verifiedInboxID,
            scope: scope
        )
    }

    func pendingWorkIDs(scope: V2LocalWorkScope) throws -> [WorkID] {
        try workRepository.pendingWorkIDs(scope: scope)
    }
}
