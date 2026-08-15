import Foundation
import NovelCore
import NovelSync

extension AppleDeviceSyncLibraryOpenCoordinator {
    /// Returns identity only for exact revisions that can be resumed without
    /// consulting the moving remote catalog. No title or catalog projection
    /// crosses this recovery boundary.
    func offlineResumablePendingOpenWorkIDs() async -> [SyncWorkID] {
        let workIDs = await metadataStore.snapshot().pendingLibraryOpens.keys.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        var resumable: [SyncWorkID] = []
        resumable.reserveCapacity(workIDs.count)
        for workID in workIDs {
            guard await canResumePendingOpenOffline(workID) else { continue }
            resumable.append(workID)
        }
        return resumable
    }

    /// Attests only the Domain-owned half of a completed remote open. The App
    /// must separately attest the installed package against `expected` before
    /// promoting its registry record.
    func hasCompletedRemoteOpenLocally(_ expected: SyncWorkLibraryEntry) async -> Bool {
        do {
            try expected.validate()
            let locator = try AppleLocalDocumentLocator.cloudLibrary(workID: expected.workID)
            let metadata = await metadataStore.snapshot()
            guard metadata.accountScope != nil,
                  metadata.pendingLibraryOpens[expected.workID] == nil,
                  metadata.pendingWorkCreations[locator] == nil,
                  let binding = metadata.bindings[locator],
                  binding.binding.workID == expected.workID else {
                return false
            }

            let workJournal = try await journalFactory.workJournal(for: binding.binding)
            guard let record = try await workJournal.load(for: expected.workID) else {
                return false
            }
            try record.validate()
            try expected.requireCatalogIdentity(record.localHead)
            let document = try record.localHead.snapshot.materializedDocument()
            let episodeIDs = Set(document.chapters.flatMap(\.episodes).map(\.id))
            guard record.workID == expected.workID,
                  record.localWorkingCopyID == binding.binding.localWorkingCopyID,
                  record.replicaID == replicaID,
                  record.lastKnownRemoteHead == record.localHead,
                  record.outbox.isEmpty,
                  record.sealedPublish == nil,
                  record.stagedLocalRevision == nil,
                  record.retainedLocalRecoveryRevision == nil,
                  record.conflictReview == nil,
                  binding.allowedEpisodeIDs == episodeIDs,
                  isCompletedRemoteOpenState(record) else {
                return false
            }

            // Fence a concurrent rebind after the journal read. App document
            // operations provide the outer serialization; this second actor
            // snapshot prevents an already-replaced binding from attesting.
            let finalMetadata = await metadataStore.snapshot()
            return finalMetadata.bindings[locator] == binding
                && finalMetadata.pendingLibraryOpens[expected.workID] == nil
                && finalMetadata.pendingWorkCreations[locator] == nil
        } catch {
            return false
        }
    }

    private func isCompletedRemoteOpenState(_ record: WorkSyncJournalRecord) -> Bool {
        if let pending = record.pendingRemoteMaterialization {
            return pending.kind == .remoteBootstrap
                && pending.sourceLocalRevisionID == record.localHead.revisionID
                && pending.revision == record.localHead
                && record.reconciliationStatus == .materializationRequired
        }
        return record.reconciliationStatus == .synchronized
            || record.reconciliationStatus == .offline
    }
}

public extension AppleDeviceSyncServices {
    /// Identity-only recovery inventory for an App-registry crash window. An
    /// account-change signal fences the prior account before IDs are exposed.
    func offlineResumablePendingOpenWorkIDs() async -> [SyncWorkID] {
        guard case .ready = await accountGate.availability() else { return [] }
        return await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).offlineResumablePendingOpenWorkIDs()
    }

    /// Local binding/journal proof only. Installed-package attestation remains
    /// an App responsibility.
    func hasCompletedRemoteOpenLocally(_ expected: SyncWorkLibraryEntry) async -> Bool {
        await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).hasCompletedRemoteOpenLocally(expected)
    }
}

public extension AppleDeviceSyncBlockedServices {
    /// A transient account lookup failure is not evidence of an account change.
    /// Account-required, mismatch, and runtime failures remain quarantined.
    func offlineResumablePendingOpenWorkIDs() async -> [SyncWorkID] {
        guard reason == .temporarilyUnavailable else { return [] }
        let metadata = await metadataStore.snapshot()
        guard metadata.accountScope != nil else { return [] }
        return await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).offlineResumablePendingOpenWorkIDs()
    }

    /// Local proof does not authorize remote access or upload under an
    /// unavailable or different account.
    func hasCompletedRemoteOpenLocally(_ expected: SyncWorkLibraryEntry) async -> Bool {
        await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).hasCompletedRemoteOpenLocally(expected)
    }
}
