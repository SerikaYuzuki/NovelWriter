import Foundation
import NovelSyncV2
import NovelSyncV2Store

/// Read-only, scope-checked bytes used to validate downloaded snapshot graphs.
protocol SnapshotCache: Sendable {
    func committedSnapshot(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) async throws -> EncodedSnapshot?
    func verifiedInboxSnapshot(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) async throws -> EncodedSnapshot?
    func isBoundary(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) async throws -> Bool
    func historyIsIncomplete(workID: WorkID, scope: V2LocalWorkScope) async throws -> Bool
}

/// Backfill commits remain a separate capability. Each page and its cursor
/// still commit in the store's single transaction, never through the cache.
protocol HistoryBackfillPersistence: Sendable {
    func backfillWorkIDs() async throws -> [WorkID]
    func resumeBackfill(workID: WorkID, binding: V2AccountBinding, manual: Bool) async throws -> V2BackfillState?
    func setBackfillStatus(workID: WorkID, binding: V2AccountBinding, status: V2BackfillStatus, failureCode: String?) async throws
    func backfillObject(_ entry: SnapshotEntry, workID: WorkID, binding: V2AccountBinding) async throws -> Data?
    func applyBackfillPage(_ page: V2BackfillPage, workID: WorkID, binding: V2AccountBinding,
                           root: SnapshotID, expectedCursor: String?) async throws
}

extension LocalSyncV2Store: SnapshotCache, HistoryBackfillPersistence {}
