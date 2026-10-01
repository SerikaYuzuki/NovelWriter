import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWritingSupport

/// Explicit capabilities of this test double.
extension PriorityOperationPlanner {
    func requestSynchronization(workID _: WorkID) async throws {}

    func automaticSyncCandidate(workID _: WorkID) async throws -> SyncV2AutomaticSyncCandidate? {
        nil
    }

    func requestAutomaticSynchronization(workID _: WorkID, candidate _: SyncV2AutomaticSyncCandidate) async throws -> Bool {
        false
    }

    func pendingWorkIDs() async throws -> [WorkID] {
        []
    }
}
