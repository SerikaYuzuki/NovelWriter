import Foundation
@testable import FUMINIWA
import NovelLocalStore
import Testing

@Suite("Snapshot sync conflict projection")
struct SnapshotSyncConflictProjectionTests {
    @Test("resolved server choice removes the stale macOS conflict projection")
    func emptyServerConflictListClearsProjection() {
        let conflict = SnapshotSyncConflict(
            conflictID: UUID(),
            workID: UUID(),
            baseSnapshotID: nil,
            localSnapshotID: "local",
            remoteSnapshotID: "remote",
            state: "needsChoice",
            createdAt: "2026-08-17T00:00:00Z"
        )

        #expect(AppState.snapshotConflictProjection([conflict]) == conflict)
        #expect(AppState.snapshotConflictProjection([]) == nil)
    }
}
