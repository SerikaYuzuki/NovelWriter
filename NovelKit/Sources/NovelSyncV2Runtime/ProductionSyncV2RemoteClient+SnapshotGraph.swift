import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    func fetchRemoteOnlyGraph(
        workID: WorkID, id: SnapshotID, session: FuminiwaSession
    ) async throws -> [EncodedSnapshot] {
        let traversal = SnapshotFetchTraversal()
        let batch = try await downloadSnapshotPages(workID: workID, id: id, session: session)
        if let batch {
            traversal.objects = batch.objects
            for (snapshotID, value) in batch.manifests {
                try Task.checkCancellation()
                try traversal.include(value.manifest)
                let objects = try await fetchObjects(manifest: value.manifest, session: session, traversal: traversal)
                traversal.memo[snapshotID] = EncodedSnapshot(
                    manifest: value.manifest, manifestBytes: value.bytes, objects: objects
                )
            }
        }
        let snapshots = try await fetchSnapshot(workID: workID, id: id, session: session, traversal: traversal)
        if let batch, snapshots.count != batch.manifests.count {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        return snapshots
    }

    func inbox(
        command: SealedCommand,
        receipt: SyncV2ReceiptReadback,
        session: FuminiwaSession
    ) async throws -> SyncV2RemoteInbox? {
        guard let head = receipt.remoteHead else {
            return nil
        }
        let workID = try remoteClientWorkID(for: command)
        let snapshots = try await fetchSnapshot(
            workID: workID,
            id: head.snapshotID,
            session: session,
            traversal: SnapshotFetchTraversal()
        )
        return try SyncV2RemoteInbox(
            inboxID: UUID(),
            workID: workID,
            headSnapshotID: head.snapshotID,
            snapshots: snapshots,
            expectedCurrentSnapshotID: command.sourceSnapshotId,
            expectedLocalGeneration: command.sourceGeneration,
            expectedRemoteHead: SyncV2RemoteHead(
                snapshotID: head.snapshotID,
                generation: head.generation
            )
        )
    }

    func fetchSnapshot(
        workID: WorkID,
        id: SnapshotID,
        session: FuminiwaSession,
        traversal: SnapshotFetchTraversal
    ) async throws -> [EncodedSnapshot] {
        var pending: [(id: SnapshotID, finishing: Bool)] = [(id, false)]
        var result: [EncodedSnapshot] = []
        while let next = pending.popLast() {
            try Task.checkCancellation()
            if traversal.completed.contains(next.id) {
                continue
            }
            if next.finishing {
                guard let snapshot = traversal.memo[next.id] else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
                traversal.active.remove(next.id)
                traversal.completed.insert(next.id)
                result.append(snapshot)
                if result.count.isMultiple(of: 32) {
                    await Task.yield()
                }
                continue
            }
            guard traversal.active.insert(next.id).inserted else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            let scope = V2LocalWorkScope.bound(V2AccountBinding(
                accountID: session.accountID, accountFence: session.accountFence,
                serverInstanceID: session.serverInstanceID.uuidString.lowercased()
            ))
            if traversal.memo[next.id] == nil,
               let snapshot = try await localStore?.committedSnapshot(
                   workID: workID, snapshotID: next.id, scope: scope
               ) {
                // Committed parents remain a verified lineage anchor in SQLite.
                try traversal.include(snapshot.manifest)
                traversal.memo[next.id] = snapshot
                pending.append((next.id, true))
                continue
            }
            let snapshot = try await loadUncommittedSnapshot(
                workID: workID, id: next.id, scope: scope,
                session: session, traversal: traversal
            )
            traversal.memo[next.id] = snapshot
            pending.append((next.id, true))
            for parent in snapshot.manifest.parentSnapshotIds.reversed() {
                pending.append((parent, false))
            }
        }
        return result
    }

    private func loadUncommittedSnapshot(
        workID: WorkID, id: SnapshotID, scope: V2LocalWorkScope,
        session: FuminiwaSession, traversal: SnapshotFetchTraversal
    ) async throws -> EncodedSnapshot {
        if let prefetched = traversal.memo[id] {
            return prefetched
        }
        if let cached = try await localStore?.verifiedInboxSnapshot(
            workID: workID, snapshotID: id, scope: scope
        ) {
            try traversal.include(cached.manifest)
            return cached
        }
        let (manifest, bytes) = try await fetchManifest(id: id, session: session)
        guard manifest.workId == workID else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        try traversal.include(manifest)
        let objects = try await fetchObjects(manifest: manifest, session: session, traversal: traversal)
        return EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: objects)
    }

    private func fetchManifest(
        id: SnapshotID,
        session: FuminiwaSession
    ) async throws -> (SnapshotManifest, Data) {
        var request = URLRequest(
            url: origin.url.appendingPathComponent(
                "v2/snapshots/\(id.rawValue)/manifest"
            )
        )
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: binding(for: session))
        let (data, response) = try await requestSnapshotData(request, session: session)
        let contentType = httpContentType(response)
        let cacheControl = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Cache-Control")?.lowercased()
        let pragma = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Pragma")?.lowercased()
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              cacheControl == "no-store",
              pragma == "no-cache",
              contentType == mediaType,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["manifestBase64URL"] as? String,
              let digestRaw = object["manifestBytesDigest"] as? String,
              let bytes = Data(base64URL: raw),
              SnapshotID(data: bytes) == id,
              ObjectID(data: bytes).rawValue == digestRaw,
              object["snapshotId"] as? String == id.rawValue,
              object["result"] as? String == "noChanges" else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        return try (SnapshotValidator.validate(manifestBytes: bytes), bytes)
    }

    private func fetchObjects(
        manifest: SnapshotManifest,
        session: FuminiwaSession,
        traversal: SnapshotFetchTraversal
    ) async throws -> [ObjectID: Data] {
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            try Task.checkCancellation()
            if let bytes = traversal.objects[entry.objectId] {
                guard bytes.count == entry.byteCount else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
                objects[entry.objectId] = bytes
                continue
            }
            let bytes = try await fetchObject(
                entry: entry,
                session: session
            )
            traversal.objects[entry.objectId] = bytes
            objects[entry.objectId] = bytes
        }
        return objects
    }

    private func fetchObject(
        entry: SnapshotEntry,
        session: FuminiwaSession
    ) async throws -> Data {
        var request = URLRequest(
            url: origin.url.appendingPathComponent(
                "v2/objects/\(entry.objectId.rawValue)"
            )
        )
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: binding(for: session))
        let (rawObject, response) = try await requestSnapshotData(request, session: session)
        let contentType = httpContentType(response)
        let cacheControl = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Cache-Control")?.lowercased()
        let pragma = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Pragma")?.lowercased()
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              cacheControl == "no-store",
              pragma == "no-cache",
              contentType == "application/octet-stream",
              http.value(forHTTPHeaderField: "X-Fuminiwa-Object-Digest") ==
              entry.objectId.rawValue,
              Int(http.value(forHTTPHeaderField: "X-Fuminiwa-Byte-Count") ?? "") ==
              rawObject.count,
              rawObject.count == entry.byteCount,
              ObjectID(data: rawObject) == entry.objectId else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        return rawObject
    }

    private func binding(for session: FuminiwaSession) -> SealedCommand.Binding {
        SealedCommand.Binding(
            accountFence: session.accountFence,
            accountId: session.accountID,
            protocolEpoch: 2,
            serverInstanceId: session.serverInstanceID.uuidString.lowercased()
        )
    }
}

final class SnapshotFetchTraversal: @unchecked Sendable {
    // The v2 contract bounds unique objects, not the number of history versions.
    private let maximumObjects: Int
    private var objectIDs: Set<ObjectID> = []

    init(maximumObjects: Int = SnapshotSyncV2Limits.maxEntries) {
        self.maximumObjects = maximumObjects
    }

    func include(_ manifest: SnapshotManifest) throws {
        for entry in manifest.entries {
            objectIDs.insert(entry.objectId)
            guard objectIDs.count <= maximumObjects else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
        }
    }

    var active: Set<SnapshotID> = []
    var completed: Set<SnapshotID> = []
    var memo: [SnapshotID: EncodedSnapshot] = [:]
    /// Scoped to one authenticated graph fetch; never shared across accounts.
    var objects: [ObjectID: Data] = [:]
}

func remoteClientWorkID(for command: SealedCommand) throws -> WorkID {
    guard let object = try JSONSerialization.jsonObject(with: command.payloadBytes)
        as? [String: Any] else {
        throw SyncV2Failure.receiptMismatch
    }
    guard let raw = (object["workId"] as? String) ??
        (object["sourceWorkId"] as? String) else {
        throw SyncV2Failure.receiptMismatch
    }
    return try WorkID(uuidString: raw)
}

private extension Data {
    init?(base64URL value: String) {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
