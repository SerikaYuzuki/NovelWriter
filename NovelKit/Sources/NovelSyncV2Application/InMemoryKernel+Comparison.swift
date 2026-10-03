import Foundation
import NovelSyncV2

public extension InMemorySyncV2RuntimeState {
    func localSnapshotManifest(workID: WorkID, snapshotID: SnapshotID) throws -> SnapshotManifest? {
        guard let work = works[workID] else { throw SyncV2ApplicationError.workNotFound }
        return work.encoded[snapshotID]?.manifest ?? comparisonInbox(workID: workID, snapshotID: snapshotID)?.manifest
    }

    func localSnapshotObject(workID: WorkID, snapshotID: SnapshotID, entry: SnapshotEntry) throws -> Data {
        guard let encoded = works[workID]?.encoded[snapshotID] ?? comparisonInbox(workID: workID, snapshotID: snapshotID),
              encoded.manifest.entries.contains(entry), let bytes = encoded.objects[entry.objectId] else {
            throw SyncV2ApplicationError.workNotFound
        }
        return bytes
    }
}
