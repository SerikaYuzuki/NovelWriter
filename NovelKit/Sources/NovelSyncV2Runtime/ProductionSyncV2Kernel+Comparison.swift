import Foundation
import NovelSyncV2

extension ProductionSyncV2Kernel {
    func episodeBodyVersions(workID: WorkID, episodeKey: String) async throws -> [SnapshotID: SnapshotEntry] {
        try await store.episodeBodyVersions(workID: workID, episodeKey: episodeKey, scope: scope.existingScope(workID: workID))
    }

    func localSnapshotManifest(workID: WorkID, snapshotID: SnapshotID) async throws -> SnapshotManifest? {
        try await store.comparisonManifest(workID: workID, snapshotID: snapshotID, scope: scope.existingScope(workID: workID))
    }

    func localSnapshotObject(workID: WorkID, snapshotID: SnapshotID, entry: SnapshotEntry) async throws -> Data {
        try await store.comparisonObject(workID: workID, snapshotID: snapshotID, entry: entry,
                                         scope: scope.existingScope(workID: workID))
    }
}
