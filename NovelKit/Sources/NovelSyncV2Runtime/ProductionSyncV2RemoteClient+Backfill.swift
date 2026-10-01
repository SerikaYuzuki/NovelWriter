import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    func backfillWorkIDs() async throws -> [WorkID] {
        try await localStore?.backfillWorkIDs() ?? []
    }

    func backfillHistory(workID: WorkID, progress: @escaping @Sendable () async -> Void = {}) async throws {
        guard let store = localStore else { return }
        let session = try await loadSession()
        let binding = V2AccountBinding(accountID: session.accountID, accountFence: session.accountFence,
                                       serverInstanceID: session.serverInstanceID.uuidString.lowercased())
        guard let state = try await store.resumeBackfill(workID: workID, binding: binding) else { return }
        do {
            try await SnapshotDownloadContext.$current.withValue(SnapshotDownloadContext(session: session, backgroundBackfill: true)) {
                try await downloadBackfill(state, session: session, store: store, progress: progress)
            }
        } catch {
            let status: V2BackfillStatus = switch error {
            case SyncV2Failure.authenticationRequired, SyncV2Failure.fatal(.remoteDataUnavailable),
                 SyncV2Failure.fatal(.remoteWorkDeleted): .suspended
            case SyncV2Failure.quarantined, SyncV2StoreError.invalidSnapshot, is SyncV2TypeError: .failed
            default: .paused
            }
            try await store.setBackfillStatus(workID: workID, binding: binding, status: status,
                                              failureCode: status == .failed ? "invalidRemoteData" : nil)
            throw error
        }
    }

    private func downloadBackfill(_ state: V2BackfillState, session: FuminiwaSession, store: LocalSyncV2Store, progress: @Sendable () async -> Void) async throws {
        var cursor = state.resumeCursor
        var committedCursor = state.resumeCursor
        var seen = Set<String>()
        let traversal = SnapshotFetchTraversal()
        var pendingObjects: [ObjectID: Data] = [:]
        while true {
            try Task.checkCancellation()
            var request = try downloadPageRequest(workID: state.workID, id: state.rootSnapshotID,
                                                  cursor: cursor, session: session, includeTotals: cursor == nil, mode: "backfill")
            request.allowsConstrainedNetworkAccess = false
            let (data, response) = try await requestSnapshotData(request, session: session)
            let page = try await Self.decodeDownloadPage(data, response: response, id: state.rootSnapshotID,
                                                         allowsTotals: cursor == nil, mode: "backfill")
            _ = try Self.validateModeCursor(page.cursor, mode: "backfill", workID: state.workID,
                                            root: state.rootSnapshotID, session: session)
            let resumeID = try Self.validateModeCursor(page.resumeCursor, mode: "backfill", workID: state.workID,
                                                       root: state.rootSnapshotID, session: session)
            let items = try await Self.validatePageItems(page.items, workID: state.workID)
            var snapshots: [EncodedSnapshot] = []
            for item in items {
                if let manifest = item.manifest {
                    try traversal.include(manifest)
                    let referenced = Set(manifest.entries.map(\.objectId))
                    guard Set(pendingObjects.keys).isSubset(of: referenced) else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
                    for entry in manifest.entries where traversal.objects[entry.objectId] == nil && pendingObjects[entry.objectId] == nil {
                        if let bytes = try await store.backfillObject(entry, workID: state.workID, binding: state.binding) {
                            traversal.objects[entry.objectId] = bytes
                        } else if entry.byteCount <= 256 * 1024 {
                            throw SyncV2Failure.quarantined(.invalidRemoteData)
                        }
                    }
                    for (id, bytes) in pendingObjects {
                        guard traversal.objects[id] == nil else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
                        traversal.objects[id] = bytes
                    }
                    let objects = try await fetchObjects(entries: manifest.entries, session: session, traversal: traversal)
                    snapshots.append(EncodedSnapshot(manifest: manifest, manifestBytes: item.bytes, objects: objects))
                    pendingObjects = [:]
                } else {
                    let id = try ObjectID(rawValue: item.id)
                    guard pendingObjects.updateValue(item.bytes, forKey: id) == nil,
                          traversal.objects[id] == nil,
                          pendingObjects.count <= SnapshotSyncV2Limits.maxEntries else {
                        throw SyncV2Failure.quarantined(.invalidRemoteData)
                    }
                }
            }
            guard snapshots.last.map({ $0.snapshotId == resumeID }) ?? (page.resumeCursor == committedCursor) else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            guard page.cursor != nil || pendingObjects.isEmpty else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
            try Task.checkCancellation()
            let current = try await loadSession()
            guard current.binding == session.binding else { throw SyncV2Failure.accountFenceChanged }
            try await store.applyBackfillPage(V2BackfillPage(snapshots: snapshots, resumeCursor: page.resumeCursor,
                                                             terminal: page.cursor == nil),
                                              workID: state.workID, binding: state.binding, root: state.rootSnapshotID,
                                              expectedCursor: committedCursor)
            await progress()
            committedCursor = page.resumeCursor
            guard let next = page.cursor else { return }
            guard seen.insert(next).inserted else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
            cursor = next
            await Task.yield()
        }
    }
}
