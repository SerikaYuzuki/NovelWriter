import Foundation
import NovelSyncV2

public extension SyncV2Application {
    func pendingDeletionWorkIDs() async throws -> Set<WorkID> {
        try await Set(kernel.workDeletions().filter { !$0.completed }.map(\.workID))
    }

    func deletedWorkIDs() async throws -> Set<WorkID> {
        try await Set(kernel.workDeletions().filter(\.completed).map(\.workID))
    }

    func deleteWork(workID: WorkID) async throws {
        guard runtimeIdentity != .preview,
              remoteSchedulingSuspensions.isEmpty else { throw SyncV2ApplicationError.safeBoundaryRejected }
        if let task = lanes[workID, default: WorkLane()].deletionTask {
            return try await task.value
        }
        let task = Task { try await self.performWorkDeletion(workID: workID) }
        lanes[workID, default: WorkLane()].deletionTask = task
        defer { lanes[workID, default: WorkLane()].deletionTask = nil }
        try await task.value
    }

    @discardableResult
    func prepareWorkDeletion(workID: WorkID) async throws -> SyncV2WorkDeletion {
        guard runtimeIdentity != .preview,
              remoteSchedulingSuspensions.isEmpty else { throw SyncV2ApplicationError.safeBoundaryRejected }
        let deletion = try await kernel.prepareWorkDeletion(workID: workID)
        setLaneFlag(\.deletionPending, workID: workID, value: true)
        cancelWorker(for: workID)
        await planner.invalidateCaches(for: [workID])
        return deletion
    }

    private func performWorkDeletion(workID: WorkID) async throws {
        let deletion = try await prepareWorkDeletion(workID: workID)
        if !deletion.completed {
            if let binding = deletion.binding {
                try await remote.deleteWork(workID: workID, binding: binding)
            }
            try await kernel.completeWorkDeletion(deletion)
        }
        lanes[workID, default: WorkLane()].session = nil
        lanes[workID, default: WorkLane()].syncDiagnostic = nil
        updateLaneState(nil, workID: workID)
    }
}
