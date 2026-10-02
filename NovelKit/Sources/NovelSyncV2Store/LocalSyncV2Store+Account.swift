import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func rebindWork(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding
    ) throws {
        guard old != new else { return }
        try inTransaction {
            try accountRepository.retireBinding(workID: workID, from: old, to: new)
        }
    }

    /// Atomically transitions every active Work in the supplied source scope.
    /// A nil source is the cold-launch reconciliation case: all active lanes
    /// are classified against the attested destination. A non-nil source is
    /// exact; if the database has active rows but none match it, the operation
    /// fails rather than guessing another binding to park.
    func transitionAccountScopes(
        from old: V2AccountBinding?,
        to new: V2AccountBinding?
    ) throws {
        try inTransaction {
            let activeRows = try accountRepository.activeBindingRows()
            let selectedRows = try accountRepository.selectedTransitionRows(
                activeRows: activeRows,
                from: old,
                to: new
            )
            for row in selectedRows {
                let source = try accountRepository.binding(from: row)
                guard let workText = row.workID,
                      let workUUID = UUID(uuidString: workText) else {
                    throw SyncV2StoreError.invalidLifecycle
                }
                let destination = new.flatMap {
                    $0.accountID == source.accountID &&
                        $0.serverInstanceID == source.serverInstanceID &&
                        $0.protocolEpoch == source.protocolEpoch ? $0 : nil
                }
                if destination != source {
                    try accountRepository.retireBinding(
                        workID: WorkID(workUUID),
                        from: source,
                        to: destination
                    )
                }
            }
            if let new {
                try accountRepository.reactivateMatchingParkedBindings(to: new)
            }
        }
    }

    /// Retires an account binding without creating a destination binding.
    /// The Work remains editable through the local parked scope, while all
    /// old-account remote lanes are parked atomically.
    func parkWork(
        workID: WorkID,
        binding: V2AccountBinding
    ) throws {
        try inTransaction {
            try accountRepository.retireBinding(workID: workID, from: binding, to: nil)
        }
    }

    /// Parked local checkpoints must never leave an actionable unbound intent
    /// behind. This also coalesces legacy parked saves before a same-namespace
    /// reactivation creates its fresh bound checkpoint intent.
    func parkPendingUnboundIntents(workID: WorkID) throws {
        try accountRepository.parkPendingUnboundIntents(workID: workID)
    }
}

public struct V2WorkDeletion: Sendable, Equatable {
    public let workID: WorkID
    public let binding: V2AccountBinding?
    public let completed: Bool
}

public extension LocalSyncV2Store {
    /// Persist intent before any HTTP. All ordinary writers fail closed once present.
    func prepareWorkDeletion(workID: WorkID, activeBinding: V2AccountBinding?) throws -> V2WorkDeletion {
        try inTransaction {
            try deletionRepository.prepareWorkDeletionInTransaction(workID: workID, activeBinding: activeBinding)
        }
    }

    func workDeletion(workID: WorkID) throws -> V2WorkDeletion? {
        try deletionRepository.workDeletion(workID: workID)
    }

    func workDeletionIDs(completedOnly: Bool = false) throws -> Set<WorkID> {
        try deletionRepository.workDeletionIDs(completedOnly: completedOnly)
    }

    /// Only call after the matching server DELETE succeeds (or for never-bound work).
    /// Remove the full FK graph and exclusively owned BLOBs in one transaction.
    func completeWorkDeletion(_ deletion: V2WorkDeletion) throws {
        try inTransaction {
            try deletionRepository.completeWorkDeletionInTransaction(deletion)
        }
    }
}

public extension LocalSyncV2Store {
    /// Explicit rescue never inherits an account binding or resumes an old outbox.
    func rescueLocalWork(
        sourceWorkID: WorkID, sourceScope: V2LocalWorkScope,
        newWorkID: WorkID, newDocumentID: DocumentID
    ) throws -> V2OpenResult {
        guard sourceWorkID != newWorkID, try !workRepository.workExists(workID: newWorkID) else {
            throw SyncV2StoreError.staleCAS
        }
        let source = try workRepository.open(workID: sourceWorkID, scope: sourceScope)
        guard var document = source.document else { throw SyncV2StoreError.workNotFound }
        document.id = newDocumentID.rawValue
        _ = try checkpoint(V2CheckpointRequest(
            workID: newWorkID, document: document, documentCreatedAt: source.documentCreatedAt,
            expectedGeneration: 0, attachments: source.attachments, resources: source.resources
        ), scope: .unbound)
        return try workRepository.open(workID: newWorkID, scope: .unbound)
    }
}
