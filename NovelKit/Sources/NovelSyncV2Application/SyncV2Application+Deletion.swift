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
        if let task = deletionTasks[workID] {
            return try await task.value
        }
        let task = Task { try await self.performWorkDeletion(workID: workID) }
        deletionTasks[workID] = task
        defer { deletionTasks[workID] = nil }
        try await task.value
    }

    @discardableResult
    func prepareWorkDeletion(workID: WorkID) async throws -> SyncV2WorkDeletion {
        guard runtimeIdentity != .preview,
              remoteSchedulingSuspensions.isEmpty else { throw SyncV2ApplicationError.safeBoundaryRejected }
        let deletion = try await kernel.prepareWorkDeletion(workID: workID)
        deletingWorkIDs.insert(workID)
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
        sessions[workID] = nil
        syncDiagnostics[workID] = nil
        states[workID] = nil
    }
}
