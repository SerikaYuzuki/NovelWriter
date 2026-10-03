import Foundation
import NovelSyncV2

public struct SyncV2AutomaticSyncCandidate: Sendable {
    public let acknowledgedSnapshotID: SnapshotID?
    public let generation: Int64
    public let head: SyncV2RemoteHead
    public let binding: SyncV2AccountScopeBinding

    public init(generation: Int64, head: SyncV2RemoteHead, binding: SyncV2AccountScopeBinding, acknowledgedSnapshotID: SnapshotID? = nil) {
        self.acknowledgedSnapshotID = acknowledgedSnapshotID
        self.generation = generation
        self.head = head
        self.binding = binding
    }
}

public extension SyncV2Application {
    /// Called only after the platform's existing body/session/IME guards accept an edit.
    func recordBodyEdit(workID: WorkID) {
        lanes[workID, default: WorkLane()].lastBodyEdit = promotionClock.now()
    }

    internal func foregroundPollDelay(workID: WorkID, since lastCheck: Date, failed: Bool) -> TimeInterval {
        let now = promotionClock.now()
        let typing = lanes[workID]?.lastBodyEdit.map {
            now.timeIntervalSince($0) < timing.headPollTypingWindowSeconds
        } ?? false
        let interval = failed ? timing.headPollFailureSeconds :
            (typing ? timing.headPollTypingSeconds : timing.headPollNormalSeconds)
        return max(0, interval - now.timeIntervalSince(lastCheck))
    }

    internal func pollForeground(
        workID: WorkID,
        refresh: @Sendable () async -> Void
    ) async {
        var lastCheck: Date?
        var failed = false
        while !Task.isCancelled {
            if let lastCheck {
                let remaining = foregroundPollDelay(workID: workID, since: lastCheck, failed: failed)
                if remaining > 0 {
                    // Re-evaluate typing while waiting. Returning to idle must not
                    // leave the remainder of a 120-second sleep outstanding.
                    var delay = failed ? remaining : min(remaining, timing.headPollNormalSeconds)
                    if !failed, let edited = lanes[workID]?.lastBodyEdit {
                        let untilIdle = timing.headPollTypingWindowSeconds - promotionClock.now().timeIntervalSince(edited)
                        if untilIdle > 0 {
                            delay = min(delay, untilIdle)
                        }
                    }
                    do { try await automaticSyncSleep(UInt64(delay * 1_000_000_000)) }
                    catch { return }
                    continue
                }
            }
            failed = false
            do {
                _ = try await checkForRemoteUpdates(workID: workID)
            } catch is CancellationError {
                return
            } catch {
                // A read failure must not quarantine a command or show a modal.
                failed = true
            }
            lastCheck = promotionClock.now()
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// A cheap read detects a changed head. Already received content follows
    /// the verified graph read path; unreceived content keeps its publish lane.
    /// Both retain concurrent-edit/account checks and the document gate.
    @discardableResult
    func checkForRemoteUpdates(workID: WorkID) async throws -> Bool {
        guard runtimeIdentity != .preview,
              remoteSchedulingSuspensions.isEmpty,
              !lanes[workID, default: WorkLane()].deletionPending,
              setLaneFlag(\.automaticCheckInProgress, workID: workID, value: true) else { return false }
        defer { setLaneFlag(\.automaticCheckInProgress, workID: workID, value: false) }
        let scopeGeneration = historyScopeGeneration
        guard let candidate = try await planner.automaticSyncCandidate(workID: workID),
              lanes[workID, default: WorkLane()].workerTask == nil else { return false }
        let state = lanes[workID, default: WorkLane()].state
        switch state?.remoteProgress ?? .idle {
        case .idle, .noChanges, .offline, .retryable, .pending:
            break
        default:
            return false
        }
        guard scopeGeneration == historyScopeGeneration,
              remoteSchedulingSuspensions.isEmpty else { return false }
        try Task.checkCancellation()
        let head = try await readAutomaticHead(workID: workID, scopeGeneration: scopeGeneration, state: state)
        try Task.checkCancellation()
        guard scopeGeneration == historyScopeGeneration,
              remoteSchedulingSuspensions.isEmpty,
              !lanes[workID, default: WorkLane()].deletionPending,
              lanes[workID, default: WorkLane()].workerTask == nil,
              let head else { return false }
        if head == candidate.head {
            if try await !kernel.hasUnpromotedLeaf(workID: workID),
               lanes[workID, default: WorkLane()].state == state, let state, state.remoteProgress != .noChanges {
                setState(workID: workID, localDurability: state.localDurability,
                         remoteProgress: .noChanges, result: .noChanges)
            }
            return false
        }
        guard head.generation > candidate.head.generation else { return false }
        if let snapshotID = candidate.acknowledgedSnapshotID {
            return try await stageAcknowledgedRemoteUpdate(workID: workID, candidate: candidate,
                                                           snapshotID: snapshotID, scopeGeneration: scopeGeneration)
        }
        guard try await planner.requestAutomaticSynchronization(
            workID: workID, candidate: candidate
        ) else { return false }
        try Task.checkCancellation()
        guard scopeGeneration == historyScopeGeneration,
              remoteSchedulingSuspensions.isEmpty else { return false }
        setState(workID: workID, localDurability: state?.localDurability ?? .unsaved,
                 remoteProgress: .pending, result: .queued)
        scheduleWorker(for: workID)
        return true
    }
}

private extension SyncV2Application {
    func readAutomaticHead(
        workID: WorkID, scopeGeneration: UInt64, state: WorkLane.State?
    ) async throws -> SyncV2RemoteHead? {
        do {
            return try await remoteReads.remoteHead(workID: workID)
        } catch {
            if !Task.isCancelled, scopeGeneration == historyScopeGeneration,
               remoteSchedulingSuspensions.isEmpty, lanes[workID, default: WorkLane()].workerTask == nil,
               lanes[workID, default: WorkLane()].state == state {
                // Project the small status indicator; no command is retried,
                // quarantined, or reported through the Debug modal channel.
                record(failure: error as? SyncV2Failure ?? .offline, workID: workID)
            }
            throw error
        }
    }
}
