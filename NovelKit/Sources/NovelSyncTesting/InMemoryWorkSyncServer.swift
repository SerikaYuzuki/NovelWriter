import NovelSync

public actor InMemoryWorkSyncServer: WorkSyncTransport {
    private struct CachedMutation: Sendable {
        let request: WorkPublishRequest
        let committedHeadID: SyncRevisionID
    }

    private var revisions: [SyncWorkID: [SyncRevisionID: WorkRevision]] = [:]
    private var headIDs: [SyncWorkID: SyncRevisionID] = [:]
    private var mutations: [SyncMutationID: CachedMutation] = [:]
    private var online = true
    private var loseNextResponse = false
    private var pauseNextPublishValue = false
    private var pausedPublish: CheckedContinuation<Void, Never>?
    private var pauseNextFetchValue = false
    private var pausedFetch: CheckedContinuation<Void, Never>?

    public init() {}

    public func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try requireOnline()
        let captured = snapshot(for: workID)
        if pauseNextFetchValue {
            pauseNextFetchValue = false
            await withCheckedContinuation { continuation in
                pausedFetch = continuation
            }
        }
        try requireOnline()
        return captured
    }

    public func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        try requireOnline()
        guard let revision = revisions[workID]?[id] else {
            throw WorkSyncTransportError.missingRevision
        }
        return revision
    }

    public func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        try requireOnline()
        if let cached = mutations[request.mutationID] {
            guard cached.request == request else { throw WorkSyncTransportError.mutationReuse }
            guard let committed = revisions[request.workID]?[cached.committedHeadID] else {
                throw WorkSyncTransportError.missingRevision
            }
            return .acknowledged(committedHead: committed, current: snapshot(for: request.workID))
        }
        if pauseNextPublishValue {
            pauseNextPublishValue = false
            await withCheckedContinuation { continuation in
                pausedPublish = continuation
            }
        }
        try requireOnline()
        try request.validate()
        let current = snapshot(for: request.workID)
        guard current.head?.revisionID == request.expectedHeadRevisionID,
              current.head?.snapshotDigest == request.expectedHeadSnapshotDigest else {
            return .diverged(current)
        }
        try validateParentAvailability(request)
        var store = revisions[request.workID] ?? [:]
        for revision in request.revisions {
            if let existing = store[revision.revisionID], existing != revision {
                throw WorkSyncTransportError.revisionCollision
            }
            store[revision.revisionID] = revision
        }
        revisions[request.workID] = store
        headIDs[request.workID] = request.candidateHeadRevisionID
        mutations[request.mutationID] = CachedMutation(
            request: request,
            committedHeadID: request.candidateHeadRevisionID
        )
        guard let committed = store[request.candidateHeadRevisionID] else {
            throw WorkSyncTransportError.missingRevision
        }
        if loseNextResponse {
            loseNextResponse = false
            throw WorkSyncTransportError.unavailable
        }
        return .acknowledged(committedHead: committed, current: snapshot(for: request.workID))
    }

    public func setOnline(_ value: Bool) {
        online = value
    }

    public func loseNextPublishResponseAfterCommit() {
        loseNextResponse = true
    }

    public func pauseNextPublish() {
        pauseNextPublishValue = true
    }

    @discardableResult
    public func waitUntilPublishIsPaused(maximumPollCount: Int = 2000) async -> Bool {
        for _ in 0 ..< maximumPollCount {
            if pausedPublish != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    public func publishIsPaused() -> Bool {
        pausedPublish != nil
    }

    public func resumePausedPublish() {
        let continuation = pausedPublish
        pausedPublish = nil
        continuation?.resume()
    }

    public func pauseNextFetchAfterCapture() {
        pauseNextFetchValue = true
    }

    @discardableResult
    public func waitUntilFetchIsPaused(maximumPollCount: Int = 2000) async -> Bool {
        for _ in 0 ..< maximumPollCount {
            if pausedFetch != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    public func fetchIsPaused() -> Bool {
        pausedFetch != nil
    }

    public func resumePausedFetch() {
        let continuation = pausedFetch
        pausedFetch = nil
        continuation?.resume()
    }

    public func currentHead(for workID: SyncWorkID) -> WorkRevision? {
        snapshot(for: workID).head
    }

    private func snapshot(for workID: SyncWorkID) -> WorkRemoteSnapshot {
        WorkRemoteSnapshot(head: headIDs[workID].flatMap { revisions[workID]?[$0] })
    }

    private func validateParentAvailability(_ request: WorkPublishRequest) throws {
        var known = Set(revisions[request.workID, default: [:]].keys)
        for revision in request.revisions {
            guard revision.parentRevisionIDs.allSatisfy(known.contains) else {
                throw WorkSyncTransportError.invalidPublishRequest
            }
            known.insert(revision.revisionID)
        }
    }

    private func requireOnline() throws {
        guard online else { throw WorkSyncTransportError.unavailable }
    }
}
