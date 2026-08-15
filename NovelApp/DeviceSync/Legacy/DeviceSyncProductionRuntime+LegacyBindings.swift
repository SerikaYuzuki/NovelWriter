#if canImport(NovelSyncCloudKit)
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

/// D-076 R5: compatibility-only whole-work outbox resume. The live library
/// first-publish overload remains in Runtime and publishes through NoteSync.
extension DeviceSyncProductionRuntimeBox {
    /// D-063 Work journal outbox resume. Tests inject a fake `WorkSyncTransport`.
    func resumeInitialWorkPublication(
        binding: SyncWorkingCopyBinding,
        journal: any WorkSyncJournal,
        transport: any WorkSyncTransport,
        initialSnapshot: WorkSnapshot,
        at date: Date
    ) async throws {
        if let existing = pendingWorkPublicationTasks[binding.workID] {
            try await existing.value
            return
        }
        let replicaID = localBootstrap.replicaID
        let task = Task {
            let coordinator = WorkSyncCoordinator(
                workID: binding.workID,
                localWorkingCopyID: binding.localWorkingCopyID,
                replicaID: replicaID,
                sessionID: SyncEditSessionID(),
                transport: transport,
                journal: journal
            )
            if let restored = try await coordinator.restore() {
                guard restored.localHead.snapshot == initialSnapshot else {
                    throw WorkSyncCoordinatorError.packageSnapshotMismatch
                }
                if restored.pendingRevisionCount == 0,
                   restored.reconciliationStatus == .synchronized {
                    return
                }
                guard restored.lastKnownRemoteHead == nil,
                      restored.stagedLocalRevision == nil,
                      restored.pendingRemoteMaterialization == nil,
                      restored.retainedLocalRecoveryRevision == nil,
                      restored.conflictReview == nil,
                      restored.reconciliationStatus == .pending
                      || restored.reconciliationStatus == .offline,
                      restored.pendingRevisionCount > 0,
                      let record = try await journal.load(for: binding.workID),
                      Self.isInitialPublicationLineage(record) else {
                    throw DeviceSyncInitialWorkPublicationError.requiresActiveDocumentPreflight
                }
            } else {
                _ = try await coordinator.bootstrapLocalSnapshot(initialSnapshot, at: date)
            }
            _ = try await coordinator.synchronize(at: date)
        }
        pendingWorkPublicationTasks[binding.workID] = task
        do {
            try await task.value
            pendingWorkPublicationTasks[binding.workID] = nil
        } catch {
            pendingWorkPublicationTasks[binding.workID] = nil
            throw error
        }
    }

    private static func isInitialPublicationLineage(_ record: WorkSyncJournalRecord) -> Bool {
        guard record.lastKnownRemoteHead == nil,
              !record.outbox.isEmpty,
              record.outbox.last == record.localHead,
              record.outbox.first?.parentRevisionIDs.isEmpty == true else { return false }
        return zip(record.outbox.dropFirst(), record.outbox).allSatisfy { pair in
            pair.0.parentRevisionIDs == [pair.1.revisionID]
        }
    }
}

#endif
