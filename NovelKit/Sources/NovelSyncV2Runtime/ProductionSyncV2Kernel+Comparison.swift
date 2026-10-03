import Foundation
import NovelSyncV2

extension ProductionSyncV2Kernel {
    func localSnapshotManifest(workID: WorkID, snapshotID: SnapshotID) async throws -> SnapshotManifest? {
        try await store.comparisonManifest(workID: workID, snapshotID: snapshotID, scope: scope.existingScope(workID: workID))
    }

    func localSnapshotObject(workID: WorkID, snapshotID: SnapshotID, entry: SnapshotEntry) async throws -> Data {
        try await store.comparisonObject(workID: workID, snapshotID: snapshotID, entry: entry,
                                         scope: scope.existingScope(workID: workID))
    }
}
