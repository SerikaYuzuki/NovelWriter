import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SnapshotDownloadBatch {
    var manifests: [SnapshotID: (manifest: SnapshotManifest, bytes: Data)] = [:]
    var objects: [ObjectID: Data] = [:]
}

extension ProductionSyncV2RemoteClient {
    /// Additive v2 optimization. Only the initial route's 404/405 permits the
    /// old-server fallback; incomplete pages and invalid bytes fail closed.
    func downloadSnapshotPages(
        workID: WorkID, id: SnapshotID, session: FuminiwaSession
    ) async throws -> SnapshotDownloadBatch? {
        var batch = SnapshotDownloadBatch()
        var cursor: String?
        var seenCursors: Set<String> = []
        var lastKey: String?
        let budget = SnapshotFetchTraversal()
        repeat {
            try Task.checkCancellation()
            let request = try downloadPageRequest(workID: workID, id: id, cursor: cursor, session: session)
            let (data, response) = try await requestSnapshotData(
                request, session: session, allowMissingEndpoint: cursor == nil
            )
            if cursor == nil, let http = response as? HTTPURLResponse, [404, 405].contains(http.statusCode) {
                return nil
            }
            let page = try decodeDownloadPage(data, response: response, id: id)
            guard let items = page["items"] as? [[String: Any]], items.count <= 256 else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            for item in items {
                let key = try appendDownloadItem(item, workID: workID, batch: &batch, budget: budget)
                guard lastKey.map({ $0 < key }) ?? true else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
                lastKey = key
            }
            if let next = page["nextCursor"] as? String {
                guard !items.isEmpty, !next.isEmpty, next.utf8.count <= 2048,
                      seenCursors.insert(next).inserted else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
                cursor = next
            } else if page["nextCursor"] is NSNull {
                cursor = nil
            } else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
        } while cursor != nil
        try validateDownloadClosure(batch, head: id)
        return batch
    }

    private func downloadPageRequest(
        workID: WorkID, id: SnapshotID, cursor: String?, session: FuminiwaSession
    ) throws -> URLRequest {
        var url = URLComponents(url: origin.url.appendingPathComponent("v2/works/\(workID.description)/download"),
                                resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "snapshotId", value: id.rawValue)] +
            (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        guard let value = url?.url else { throw SyncV2Failure.fatal(.unexpected) }
        var request = URLRequest(url: value)
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: SealedCommand.Binding(
            accountFence: session.accountFence, accountId: session.accountID,
            protocolEpoch: 2, serverInstanceId: session.serverInstanceID.uuidString.lowercased()
        ))
        return request
    }

    private func decodeDownloadPage(_ data: Data, response: URLResponse, id: SnapshotID) throws -> [String: Any] {
        guard data.count <= 24 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200, httpContentType(response) == mediaType,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache" else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        do {
            try CanonicalJSON.validate(data)
        } catch {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        let page = try checkedObject(object, keys: ["result", "snapshotId", "items", "nextCursor"])
        guard page["result"] as? String == "noChanges", page["snapshotId"] as? String == id.rawValue else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        return page
    }

    private func appendDownloadItem(
        _ item: [String: Any], workID: WorkID, batch: inout SnapshotDownloadBatch, budget: SnapshotFetchTraversal
    ) throws -> String {
        let item = try checkedObject(item, keys: ["kind", "id", "bytesBase64URL"])
        guard let kind = item["kind"] as? String, let rawID = item["id"] as? String,
              let rawBytes = item["bytesBase64URL"] as? String,
              let bytes = decodeDownloadBytes(rawBytes), ObjectID(data: bytes).rawValue == rawID else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        switch kind {
        case "manifest":
            let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
            let snapshotID = SnapshotID(data: bytes)
            guard manifest.workId == workID, batch.manifests[snapshotID] == nil else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            try budget.include(manifest)
            batch.manifests[snapshotID] = (manifest, bytes)
        case "object":
            let objectID = ObjectID(data: bytes)
            guard bytes.count <= 256 * 1024, batch.objects[objectID] == nil,
                  batch.objects.count < SnapshotSyncV2Limits.maxEntries else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            batch.objects[objectID] = bytes
        default:
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        return "\(kind):\(rawID)"
    }

    private func validateDownloadClosure(_ batch: SnapshotDownloadBatch, head: SnapshotID) throws {
        guard batch.manifests[head] != nil else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
        var referenced: Set<ObjectID> = []
        for value in batch.manifests.values {
            guard value.manifest.parentSnapshotIds.allSatisfy({ batch.manifests[$0] != nil }) else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            for entry in value.manifest.entries {
                referenced.insert(entry.objectId)
                if entry.byteCount <= 256 * 1024, batch.objects[entry.objectId] == nil {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
            }
        }
        guard Set(batch.objects.keys).isSubset(of: referenced) else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
    }

    private func decodeDownloadBytes(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64),
              bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
              .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value else { return nil }
        return bytes
    }
}
