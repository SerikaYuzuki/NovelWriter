import Foundation
import NovelSyncV2

public struct SyncV2AutomaticSyncCandidate: Sendable {
    public let generation: Int64
    public let head: SyncV2RemoteHead
    public let binding: SyncV2AccountScopeBinding

    public init(generation: Int64, head: SyncV2RemoteHead, binding: SyncV2AccountScopeBinding) {
        self.generation = generation
        self.head = head
        self.binding = binding
    }
}

public extension SyncV2Application {
    /// Application-owned cadence: 10 seconds normally, 60 after a read failure.
    internal func pollForeground(
        workID: WorkID,
        refresh: @Sendable () async -> Void
    ) async {
        while !Task.isCancelled {
            var delay: UInt64 = 10_000_000_000
            do {
                _ = try await checkForRemoteUpdates(workID: workID)
            } catch is CancellationError {
                return
            } catch {
                // A read failure must not quarantine a command or show a modal.
                delay = 60_000_000_000
            }
            guard !Task.isCancelled else { return }
            await refresh()
            do {
                try await automaticSyncSleep(delay)
            } catch { return }
        }
    }

    /// A cheap read detects a changed head. Only then does the normal publish
    /// receipt/verified-Inbox path reconcile it, retaining concurrent-edit and
    /// account protections instead of directly installing downloaded values.
    @discardableResult
    func checkForRemoteUpdates(workID: WorkID) async throws -> Bool {
        guard runtimeIdentity != .preview,
              remoteSchedulingSuspensions.isEmpty,
              !deletingWorkIDs.contains(workID),
              automaticChecks.insert(workID).inserted else { return false }
        defer { automaticChecks.remove(workID) }
        let scopeGeneration = historyScopeGeneration
        guard let candidate = try await planner.automaticSyncCandidate(workID: workID),
              workerTasks[workID] == nil else { return false }
        let state = states[workID]
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
              !deletingWorkIDs.contains(workID),
              workerTasks[workID] == nil,
              let head else { return false }
        if head == candidate.head {
            if try await !kernel.hasUnpromotedLeaf(workID: workID),
               states[workID] == state, let state, state.remoteProgress != .noChanges {
                setState(workID: workID, localDurability: state.localDurability,
                         remoteProgress: .noChanges, result: .noChanges)
            }
            return false
        }
        guard head.generation > candidate.head.generation else { return false }
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
        workID: WorkID, scopeGeneration: UInt64, state: SyncUIState?
    ) async throws -> SyncV2RemoteHead? {
        do {
            return try await libraryProvider.remoteHead(workID: workID)
        } catch {
            if !Task.isCancelled, scopeGeneration == historyScopeGeneration,
               remoteSchedulingSuspensions.isEmpty, workerTasks[workID] == nil,
               states[workID] == state {
                // Project the small status indicator; no command is retried,
                // quarantined, or reported through the Debug modal channel.
                record(failure: error as? SyncV2Failure ?? .offline, workID: workID)
            }
            throw error
        }
    }
}
