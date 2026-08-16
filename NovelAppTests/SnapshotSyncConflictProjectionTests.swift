import Foundation
@testable import FUMINIWA
import NovelLocalStore
import Testing

@MainActor
@Suite("Snapshot sync conflict projection")
struct SnapshotSyncConflictProjectionTests {
    @Test("resolved server choice removes the stale macOS conflict projection")
    func emptyServerConflictListClearsProjection() throws {
        let conflict = try JSONDecoder().decode(
            SnapshotSyncConflict.self,
            from: Data("""
            {
              "conflict_id": "00000000-0000-0000-0000-000000000001",
              "work_id": "00000000-0000-0000-0000-000000000002",
              "base_snapshot_id": null,
              "local_snapshot_id": "local",
              "remote_snapshot_id": "remote",
              "state": "needsChoice",
              "created_at": "2026-08-17T00:00:00Z"
            }
            """.utf8)
        )

        #expect(AppState.snapshotConflictProjection([conflict]) == conflict)
        #expect(AppState.snapshotConflictProjection([]) == nil)
    }
}
