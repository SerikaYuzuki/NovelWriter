import Foundation
import NovelSync

public actor InMemoryEpisodeSyncServer: EpisodeSyncTransport, SyncWorkCatalog {
    private struct LeaseSlot: Sendable {
        var epoch: UInt64 = 0
        var activeLease: EpisodeLease?
    }

    private struct CachedMutation: Sendable {
        let request: EpisodePublishRequest
        let committedHeadRevisionID: SyncRevisionID
    }

    private var workDescriptors: [SyncWorkID: SyncWorkDescriptor] = [:]
    private var revisionStores: [EpisodeSyncKey: [SyncRevisionID: EpisodeRevision]] = [:]
    private var headIDs: [EpisodeSyncKey: SyncRevisionID] = [:]
    private var leaseSlots: [EpisodeSyncKey: LeaseSlot] = [:]
    private var mutationCache: [SyncMutationID: CachedMutation] = [:]
    private var online = true, shouldLoseNextPublishResponse = false, shouldPauseNextPublish = false
    private var pausedPublishContinuation: CheckedContinuation<Void, Never>?
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func setOnline(_ online: Bool) {
        self.online = online
    }

    /// server commit後・client response前の切断を決定論的に再現する。
    public func loseNextPublishResponseAfterCommit() {
        shouldLoseNextPublishResponse = true
    }

    public func pauseNextPublish() {
        shouldPauseNextPublish = true
    }

    public func waitUntilPublishIsPaused() async {
        if pausedPublishContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            pauseObservers.append(continuation)
        }
    }

    public func resumePausedPublish() {
        let continuation = pausedPublishContinuation
        pausedPublishContinuation = nil
        continuation?.resume()
    }

    public func createWork(_ descriptor: SyncWorkDescriptor) async throws {
        try requireOnline()
        guard workDescriptors[descriptor.workID] == nil else {
            throw SyncCatalogError.duplicateWorkID
        }
        workDescriptors[descriptor.workID] = descriptor
    }

    public func listWorks() async throws -> [SyncWorkDescriptor] {
        try requireOnline()
        return workDescriptors.values.sorted { lhs, rhs in
            lhs.workID.rawValue.uuidString < rhs.workID.rawValue.uuidString
        }
    }

    public func fetchSnapshot(for key: EpisodeSyncKey) async throws -> EpisodeRemoteSnapshot {
        try requireOnline()
        return try snapshot(for: key)
    }

    public func fetchRevision(
        _ id: SyncRevisionID,
        for key: EpisodeSyncKey
    ) async throws -> EpisodeRevision {
        try requireOnline()
        guard let revision = revisionStores[key]?[id] else {
            throw EpisodeSyncTransportError.missingRevision
        }
        return revision
    }

    public func claimLease(
        _ request: EpisodeLeaseClaimRequest
    ) async throws -> EpisodeLeaseClaimResult {
        try requireOnline()
        var slot = leaseSlots[request.key] ?? LeaseSlot()
        guard request.expectedEpoch == slot.epoch else {
            return try .changed(snapshot(for: request.key))
        }

        switch request.kind {
        case .acquireOrRenew:
            if let current = slot.activeLease {
                let isSameHolder = current.authority.holderReplicaID == request.requesterReplicaID
                    && current.authority.holderSessionID == request.requesterSessionID
                guard isSameHolder else { return try .denied(snapshot(for: request.key)) }
                let renewed = EpisodeLease(authority: current.authority, expiresAt: request.expiresAt)
                slot.activeLease = renewed
                leaseSlots[request.key] = slot
                return try .granted(snapshot(for: request.key))
            }
            slot.epoch = try nextEpoch(after: slot.epoch)
        case .forceTakeover:
            slot.epoch = try nextEpoch(after: slot.epoch)
        }

        let authority = try EpisodeLeaseAuthority(
            holderReplicaID: request.requesterReplicaID,
            holderSessionID: request.requesterSessionID,
            epoch: slot.epoch
        )
        let lease = EpisodeLease(authority: authority, expiresAt: request.expiresAt)
        slot.activeLease = lease
        leaseSlots[request.key] = slot
        return try .granted(snapshot(for: request.key))
    }

    public func releaseLease(
        key: EpisodeSyncKey,
        expectedAuthority: EpisodeLeaseAuthority
    ) async throws -> EpisodeRemoteSnapshot {
        try requireOnline()
        var slot = leaseSlots[key] ?? LeaseSlot()
        if slot.activeLease?.authority == expectedAuthority {
            slot.activeLease = nil
            leaseSlots[key] = slot
        }
        return try snapshot(for: key)
    }

    public func publish(_ request: EpisodePublishRequest) async throws -> EpisodePublishResult {
        try requireOnline()
        if let cached = try cachedResult(for: request) {
            return cached
        }
        try await pauseIfRequested()

        let currentSnapshot = try snapshot(for: request.key)
        guard currentSnapshot.lease?.authority == request.expectedLeaseAuthority else {
            return .staleLease(currentSnapshot)
        }
        try validate(request)

        guard currentSnapshot.head?.revisionID == request.expectedHeadRevisionID else {
            return .diverged(currentSnapshot)
        }

        return try commit(request)
    }

    private func cachedResult(for request: EpisodePublishRequest) throws -> EpisodePublishResult? {
        guard let cached = mutationCache[request.mutationID] else { return nil }
        guard cached.request == request else { throw EpisodeSyncTransportError.mutationReuse }
        guard let committedHead = revisionStores[request.key]?[cached.committedHeadRevisionID] else {
            throw EpisodeSyncTransportError.missingRevision
        }
        return try .acknowledged(
            committedHead: committedHead,
            current: snapshot(for: request.key)
        )
    }

    private func pauseIfRequested() async throws {
        guard shouldPauseNextPublish else { return }
        shouldPauseNextPublish = false
        let observers = pauseObservers
        pauseObservers.removeAll()
        await withCheckedContinuation { continuation in
            pausedPublishContinuation = continuation
            for observer in observers {
                observer.resume()
            }
        }
        try requireOnline()
    }

    private func commit(_ request: EpisodePublishRequest) throws -> EpisodePublishResult {
        var store = revisionStores[request.key] ?? [:]
        for revision in request.revisions {
            if let existing = store[revision.revisionID], existing != revision {
                throw EpisodeSyncTransportError.revisionCollision
            }
            store[revision.revisionID] = revision
        }
        revisionStores[request.key] = store
        headIDs[request.key] = request.candidateHeadRevisionID

        let updated = try snapshot(for: request.key)
        guard let committedHead = updated.head else {
            throw EpisodeSyncTransportError.missingRevision
        }
        let result = EpisodePublishResult.acknowledged(
            committedHead: committedHead,
            current: updated
        )
        mutationCache[request.mutationID] = CachedMutation(
            request: request,
            committedHeadRevisionID: committedHead.revisionID
        )

        if shouldLoseNextPublishResponse {
            shouldLoseNextPublishResponse = false
            throw EpisodeSyncTransportError.unavailable
        }
        return result
    }

    public func storedRevisionCount(for key: EpisodeSyncKey) -> Int {
        revisionStores[key]?.count ?? 0
    }

    public func currentHead(for key: EpisodeSyncKey) -> EpisodeRevision? {
        guard let headID = headIDs[key] else { return nil }
        return revisionStores[key]?[headID]
    }

    public func currentLease(for key: EpisodeSyncKey) -> EpisodeLease? {
        leaseSlots[key]?.activeLease
    }

    public func currentLeaseEpoch(for key: EpisodeSyncKey) -> UInt64 {
        leaseSlots[key]?.epoch ?? 0
    }

    private func snapshot(for key: EpisodeSyncKey) throws -> EpisodeRemoteSnapshot {
        let slot = leaseSlots[key] ?? LeaseSlot()
        let head = headIDs[key].flatMap { revisionStores[key]?[$0] }
        return try EpisodeRemoteSnapshot(head: head, leaseEpoch: slot.epoch, lease: slot.activeLease)
    }

    private func validate(_ request: EpisodePublishRequest) throws {
        try request.validate()

        var known = Set((revisionStores[request.key] ?? [:]).keys)
        var newlyKnown: Set<SyncRevisionID> = []
        for revision in request.revisions {
            try revision.validate()
            for parent in revision.parentRevisionIDs where !known.contains(parent) && !newlyKnown.contains(parent) {
                throw EpisodeSyncTransportError.invalidPublishRequest
            }
            newlyKnown.insert(revision.revisionID)
        }
        known.formUnion(newlyKnown)
        guard known.contains(request.candidateHeadRevisionID),
              descends(
                  candidate: request.candidateHeadRevisionID,
                  from: request.expectedHeadRevisionID,
                  request: request
              ) else {
            throw EpisodeSyncTransportError.invalidPublishRequest
        }
    }

    private func descends(
        candidate: SyncRevisionID,
        from expected: SyncRevisionID?,
        request: EpisodePublishRequest
    ) -> Bool {
        let batch = Dictionary(uniqueKeysWithValues: request.revisions.map { ($0.revisionID, $0) })
        let remote = revisionStores[request.key] ?? [:]
        var pending = [candidate]
        var visited: Set<SyncRevisionID> = []

        while let revisionID = pending.popLast() {
            guard visited.insert(revisionID).inserted else { continue }
            if revisionID == expected {
                return true
            }
            guard let revision = batch[revisionID] ?? remote[revisionID] else { continue }
            if expected == nil, revision.parentRevisionIDs.isEmpty {
                return true
            }
            pending.append(contentsOf: revision.parentRevisionIDs)
        }
        return false
    }

    private func nextEpoch(after current: UInt64) throws -> UInt64 {
        guard current < EpisodeLeaseAuthority.maximumEpoch else {
            throw EpisodeSyncTransportError.leaseEpochOverflow
        }
        return current + 1
    }

    private func requireOnline() throws {
        guard online else { throw EpisodeSyncTransportError.unavailable }
    }
}
