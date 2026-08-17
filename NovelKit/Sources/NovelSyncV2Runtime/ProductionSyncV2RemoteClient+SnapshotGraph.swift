import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
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
        if traversal.memo[id] != nil {
            return []
        }
        guard !traversal.active.contains(id),
              traversal.visited.count + traversal.active.count <
              SnapshotFetchTraversal.maximumSnapshots else {
            throw SyncV2Failure.fatal(.invalidLocalState)
        }
        traversal.active.insert(id)
        defer { traversal.active.remove(id) }

        let (manifest, bytes) = try await fetchManifest(
            id: id,
            session: session
        )
        let objects = try await fetchObjects(
            manifest: manifest,
            session: session
        )
        var result = try await fetchParents(
            workID: workID,
            manifest: manifest,
            session: session,
            traversal: traversal
        )
        let snapshot = EncodedSnapshot(
            manifest: manifest,
            manifestBytes: bytes,
            objects: objects
        )
        traversal.visited.insert(id)
        traversal.memo[id] = snapshot
        result.append(snapshot)
        return result
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
        let (data, response) = try await requestData(request, session: session)
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
        session: FuminiwaSession
    ) async throws -> [ObjectID: Data] {
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            let bytes = try await fetchObject(
                entry: entry,
                session: session
            )
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
        let (rawObject, response) = try await requestData(request, session: session)
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

    private func fetchParents(
        workID: WorkID,
        manifest: SnapshotManifest,
        session: FuminiwaSession,
        traversal: SnapshotFetchTraversal
    ) async throws -> [EncodedSnapshot] {
        var result: [EncodedSnapshot] = []
        for parent in manifest.parentSnapshotIds {
            result += try await fetchSnapshot(
                workID: workID,
                id: parent,
                session: session,
                traversal: traversal
            )
        }
        return result
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
    static let maximumSnapshots = 128
    var active: Set<SnapshotID> = []
    var visited: Set<SnapshotID> = []
    var memo: [SnapshotID: EncodedSnapshot] = [:]
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
