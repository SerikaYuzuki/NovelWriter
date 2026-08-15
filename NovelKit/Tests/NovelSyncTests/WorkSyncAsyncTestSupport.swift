import Foundation
import NovelSync

@discardableResult
func stageAndConfirm(
    _ coordinator: WorkSyncCoordinator,
    snapshot: WorkSnapshot,
    at date: Date
) async throws -> WorkRevision {
    let revision = try await coordinator.stageLocalSnapshot(snapshot, at: date)
    try await coordinator.confirmLocalSnapshotMaterialized(
        revision.revisionID,
        packageSnapshot: snapshot
    )
    return revision
}

func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool,
    attempts: Int = 2000
) async -> Bool {
    for _ in 0 ..< attempts {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
