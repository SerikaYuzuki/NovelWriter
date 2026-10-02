import Foundation
import NovelSyncV2

extension SyncV2Application {
    /// A received checkpoint needs a read, not another publish command. The
    /// complete graph proves ancestry; installation still consumes the normal
    /// document gate and repeats the local generation/account checks.
    func stageAcknowledgedRemoteUpdate(
        workID: WorkID, candidate: SyncV2AutomaticSyncCandidate,
        snapshotID: SnapshotID, scopeGeneration: UInt64
    ) async throws -> Bool {
        guard let before = try await planner.automaticSyncCandidate(workID: workID),
              before.binding == candidate.binding, before.generation == candidate.generation,
              before.acknowledgedSnapshotID == snapshotID,
              historyScopeGeneration == scopeGeneration, remoteSchedulingSuspensions.isEmpty else { return false }
        let downloaded = try await remoteReads.downloadUpdate(workID: workID)
        try Task.checkCancellation()
        guard historyScopeGeneration == scopeGeneration,
              remoteSchedulingSuspensions.isEmpty,
              lanes[workID, default: WorkLane()].workerTask == nil,
              !lanes[workID, default: WorkLane()].deletionPending,
              let current = try await planner.automaticSyncCandidate(workID: workID),
              current.binding == candidate.binding,
              current.generation == candidate.generation,
              current.acknowledgedSnapshotID == snapshotID else { return false }
        guard downloaded.workID == workID,
              downloaded.headSnapshotID == downloaded.expectedRemoteHead.snapshotID,
              downloaded.expectedRemoteHead.generation > candidate.head.generation else {
            throw SyncV2Failure.receiptMismatch
        }
        if let binding = downloaded.binding {
            guard binding.accountId == candidate.binding.accountID,
                  binding.accountFence == candidate.binding.accountFence,
                  binding.serverInstanceId == candidate.binding.serverInstanceID,
                  binding.protocolEpoch == candidate.binding.protocolEpoch else {
                throw SyncV2Failure.accountFenceChanged
            }
        }
        let inbox = SyncV2RemoteInbox(
            inboxID: downloaded.inboxID, workID: workID,
            headSnapshotID: downloaded.headSnapshotID, snapshots: downloaded.snapshots,
            expectedCurrentSnapshotID: snapshotID, expectedLocalGeneration: candidate.generation,
            expectedRemoteHead: downloaded.expectedRemoteHead, binding: downloaded.binding,
            shallow: downloaded.shallow
        )
        guard historyScopeGeneration == scopeGeneration, remoteSchedulingSuspensions.isEmpty else { return false }
        try await kernel.stageRemote(inbox)
        guard historyScopeGeneration == scopeGeneration, remoteSchedulingSuspensions.isEmpty else { return false }
        try await kernel.verifyRemote(inboxID: inbox.inboxID, workID: workID)
        guard historyScopeGeneration == scopeGeneration, remoteSchedulingSuspensions.isEmpty else { return false }
        guard let pending = try await pendingAdoption(workID: workID) else { return false }
        return pending.inboxID == inbox.inboxID
    }
}

extension SyncV2Application {
    func scheduleCleanRemoteCheck(workID: WorkID) {
        guard lanes[workID, default: WorkLane()].cleanRemoteCheck.task == nil else { return }
        let owner = UUID()
        let scopeGeneration = historyScopeGeneration
        let previousWorker = lanes[workID]?.workerTask
        let task = Task {
            defer {
                if lanes[workID]?.cleanRemoteCheck.owner == owner {
                    lanes[workID]?.cleanRemoteCheck = .idle
                }
            }
            await previousWorker?.value
            guard !Task.isCancelled, historyScopeGeneration == scopeGeneration,
                  remoteSchedulingSuspensions.isEmpty else { return }
            do {
                _ = try await checkForRemoteUpdates(workID: workID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, historyScopeGeneration == scopeGeneration,
                      lanes[workID]?.cleanRemoteCheck.owner == owner else { return }
                record(failure: error as? SyncV2Failure ?? .fatal(.unexpected), workID: workID)
            }
        }
        lanes[workID, default: WorkLane()].cleanRemoteCheck = .running(owner: owner, task: task)
    }
}
