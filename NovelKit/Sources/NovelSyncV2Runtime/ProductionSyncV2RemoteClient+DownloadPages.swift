import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SnapshotDownloadBatch: Sendable {
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
        var pending: (Data, URLResponse)?
        var wantsTotals = true
        while true {
            try Task.checkCancellation()
            let request = try downloadPageRequest(workID: workID, id: id, cursor: cursor, session: session, includeTotals: cursor == nil && wantsTotals)
            let (data, response): (Data, URLResponse)
            if let pending {
                (data, response) = pending
            } else {
                (data, response) = try await requestSnapshotData(
                    request, session: session, allowMissingEndpoint: cursor == nil, allowTotalsFallback: cursor == nil && wantsTotals
                )
            }
            if cursor == nil, let http = response as? HTTPURLResponse {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if http.statusCode == 404,
                   httpContentType(response) == mediaType || object?["error"] != nil || object?["code"] != nil {
                    try await rejectKnownRemoteDeletion(workID: workID)
                    throw SyncV2Failure.fatal(.remoteDataUnavailable)
                }
                // The original server maps unknown query keys to schemaViolation/422.
                let oldQueryRejection = http.statusCode == 422 && object?["error"] as? String == "schemaViolation"
                if wantsTotals, [400, 404, 405].contains(http.statusCode) || oldQueryRejection {
                    wantsTotals = false
                    continue
                }
                if [404, 405].contains(http.statusCode) {
                    try await rejectKnownRemoteDeletion(workID: workID)
                    return nil
                }
            }
            let page = try await Self.decodeDownloadPage(data, response: response, id: id, allowsTotals: cursor == nil && wantsTotals)
            if let total = page.totalBytes {
                ImportProgress.current?.advance(total: total)
            }
            if let next = page.cursor {
                guard seenCursors.insert(next).inserted else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
            }
            // The envelope is canonical and scoped to this root. A speculative
            // response is never consumed if any item in this page fails.
            let nextRequest = try page.cursor.map {
                try downloadPageRequest(workID: workID, id: id, cursor: $0, session: session)
            }
            async let prefetched: (Data, URLResponse)? = fetchNextPage(nextRequest, session: session)
            let validated = try await Self.validatePageItems(page.items, workID: workID)
            for item in validated {
                guard lastKey.map({ $0 < item.key }) ?? true else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
                lastKey = item.key
                if let manifest = item.manifest {
                    let snapshotID = try SnapshotID(rawValue: item.id)
                    try budget.include(manifest)
                    batch.manifests[snapshotID] = (manifest, item.bytes)
                    ImportProgress.current?.advance(bytes: Int64(item.bytes.count))
                } else {
                    guard batch.objects.count < SnapshotSyncV2Limits.maxEntries else {
                        throw SyncV2Failure.quarantined(.invalidRemoteData)
                    }
                    let objectID = try ObjectID(rawValue: item.id)
                    batch.objects[objectID] = item.bytes
                    ImportProgress.current?.receivedObject(objectID, bytes: Int64(item.bytes.count))
                }
            }
            cursor = page.cursor
            pending = try await prefetched
            if cursor == nil {
                break
            }
        }
        try await Self.validateDownloadClosure(batch, head: id)
        return batch
    }

    private func downloadPageRequest(
        workID: WorkID, id: SnapshotID, cursor: String?, session: FuminiwaSession, includeTotals: Bool = false
    ) throws -> URLRequest {
        var url = URLComponents(url: origin.url.appendingPathComponent("v2/works/\(workID.description)/download"),
                                resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "snapshotId", value: id.rawValue)] +
            (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []) +
            (includeTotals ? [URLQueryItem(name: "include", value: "totals")] : [])
        guard let value = url?.url else { throw SyncV2Failure.fatal(.unexpected) }
        var request = URLRequest(url: value)
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: SealedCommand.Binding(
            accountFence: session.accountFence, accountId: session.accountID,
            protocolEpoch: 2, serverInstanceId: session.serverInstanceID.uuidString.lowercased()
        ))
        return request
    }

    private func fetchNextPage(_ request: URLRequest?, session: FuminiwaSession) async throws -> (Data, URLResponse)? {
        guard let request else { return nil }
        return try await requestSnapshotData(request, session: session)
    }

    private struct DownloadPage: Sendable {
        let items: [CanonicalJSON.Value]
        let cursor: String?
        let totalBytes: Int64?
    }

    private struct DownloadItem: Sendable {
        let key: String
        let id: String
        let bytes: Data
        let manifest: SnapshotManifest?
    }

    private nonisolated static func decodeDownloadPage(
        _ data: Data, response: URLResponse, id: SnapshotID, allowsTotals: Bool
    ) async throws -> DownloadPage {
        guard data.count <= 24 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              httpContentType(response) == "application/vnd.fuminiwa.sync.v2+jcs",
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache" else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        do {
            guard let page = try CanonicalJSON.parseObject(data).objectDictionary,
                  Set(page.keys).subtracting(allowsTotals ? ["totals"] : []) == ["result", "snapshotId", "items", "nextCursor"],
                  page["result"]?.stringContents == "noChanges", page["snapshotId"]?.stringContents == id.rawValue,
                  case let .array(items) = page["items"], items.count <= 256 else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            let cursor: String?
            if case .null = page["nextCursor"] {
                cursor = nil
            } else if let next = page["nextCursor"]?.stringContents,
                      !items.isEmpty, !next.isEmpty, next.utf8.count <= 2048 {
                cursor = next
            } else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            var totalBytes: Int64?
            if let value = page["totals"] {
                guard let totals = value.objectDictionary, Set(totals.keys) == ["items", "bytes"],
                      case let .number(count) = totals["items"], count >= 0,
                      case let .number(bytes) = totals["bytes"], bytes >= 0 else {
                    throw SyncV2Failure.quarantined(.invalidRemoteData)
                }
                totalBytes = bytes
            }
            return DownloadPage(items: items, cursor: cursor, totalBytes: totalBytes)
        } catch {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
    }

    private nonisolated static func validatePageItems(
        _ items: [CanonicalJSON.Value], workID: WorkID
    ) async throws -> [DownloadItem] {
        try items.map { value in
            try Task.checkCancellation()
            guard let item = value.objectDictionary,
                  Set(item.keys) == ["kind", "id", "bytesBase64URL"],
                  let kind = item["kind"]?.stringContents, let rawID = item["id"]?.stringContents,
                  let rawBytes = item["bytesBase64URL"]?.stringContents,
                  let bytes = Data(base64URL: rawBytes), ObjectID(data: bytes).rawValue == rawID else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            let manifest: SnapshotManifest?
            switch kind {
            case "manifest":
                manifest = try SnapshotValidator.validate(manifestBytes: bytes)
                guard manifest?.workId == workID else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
            case "object":
                guard bytes.count <= 256 * 1024 else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
                manifest = nil
            default: throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            return DownloadItem(key: "\(kind):\(rawID)", id: rawID, bytes: bytes, manifest: manifest)
        }
    }

    private nonisolated static func validateDownloadClosure(_ batch: SnapshotDownloadBatch, head: SnapshotID) async throws {
        guard batch.manifests[head] != nil else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
        var referenced: Set<ObjectID> = []
        for value in batch.manifests.values {
            try Task.checkCancellation()
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
}
