import NovelSyncV2
import NovelSyncV2Application

/// Merges already account-scoped projections. Account visibility and async
/// completion gates remain with the host; pending IDs drive its deletion status.
public enum LibraryShelf {
    public static func merge(
        localItems: [SyncV2LibraryItem],
        catalog: [SyncV2RemoteCatalogEntry],
        previousItems: [SyncV2LibraryItem],
        pendingDeletionIDs: Set<WorkID>,
        deletedIDs: Set<WorkID>
    ) -> [SyncV2LibraryItem] {
        var rows = Dictionary(uniqueKeysWithValues: localItems
            .filter { !deletedIDs.contains($0.workID) }.map { ($0.workID, $0) })
        // Deletion intents can remove a work from the ordinary projection.
        // Preserve its last title/status for explicit retry, even if remote-only.
        for item in previousItems where pendingDeletionIDs.contains(item.workID) && !deletedIDs.contains(item.workID) {
            rows[item.workID] = item
        }
        for remote in catalog where !deletedIDs.contains(remote.workID) {
            if let local = rows[remote.workID] {
                // A catalog entry must not change a parked local account boundary.
                guard local.accountState != .parkedDifferentAccount else { continue }
                rows[remote.workID] = SyncV2LibraryItem(
                    workID: local.workID,
                    title: local.availability == .remoteOnly || local.title.isEmpty ? remote.title : local.title,
                    availability: local.availability == .remoteOnly ? .remoteOnly : .cached,
                    accountState: local.accountState,
                    localGeneration: local.localGeneration,
                    remoteHead: local.remoteHead ?? remote.head,
                    remoteHeadConfirmed: local.remoteHeadConfirmed,
                    conflict: local.conflict,
                    remoteProgress: local.remoteProgress,
                    oldestUnreceivedAt: local.oldestUnreceivedAt,
                    historyBackfillNote: local.historyBackfillNote
                )
            } else {
                rows[remote.workID] = SyncV2LibraryItem(
                    workID: remote.workID, title: remote.title, availability: .remoteOnly,
                    accountState: .active, remoteHead: remote.head
                )
            }
        }
        return rows.values.sorted {
            SyncV2LibraryPresentation.precedes(title: $0.title, workID: $0.workID, otherTitle: $1.title, otherWorkID: $1.workID)
        }
    }
}
