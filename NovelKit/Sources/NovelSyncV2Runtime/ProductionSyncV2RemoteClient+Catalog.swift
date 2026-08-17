import Foundation
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox {
        guard let session = try await vault.load() else {
            throw SyncV2Failure.authenticationRequired
        }
        let binding = SealedCommand.Binding(
            accountFence: session.accountFence,
            accountId: session.accountID,
            protocolEpoch: 2,
            serverInstanceId: session.serverInstanceID.uuidString.lowercased()
        )
        var request = URLRequest(
            url: origin.url.appendingPathComponent(
                "v2/works/\(workID.description)/head"
            )
        )
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: binding)
        let (data, response) = try await requestData(request)
        let contentType = httpContentType(response)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              contentType == mediaType,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headObject = object["head"] as? [String: Any],
              let generation = (headObject["generation"] as? NSNumber)?.int64Value,
              let raw = headObject["snapshotId"] as? String else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        let head = try SyncV2RemoteHead(
            snapshotID: SnapshotID(rawValue: raw),
            generation: generation
        )
        let snapshots = try await fetchSnapshot(
            workID: workID,
            id: head.snapshotID,
            session: session,
            traversal: SnapshotFetchTraversal()
        )
        return SyncV2RemoteInbox(
            inboxID: UUID(),
            workID: workID,
            headSnapshotID: head.snapshotID,
            snapshots: snapshots,
            expectedCurrentSnapshotID: nil,
            expectedLocalGeneration: 0,
            expectedRemoteHead: head
        )
    }

    func catalogPage(
        cursor: String?,
        pageSize: Int
    ) async throws -> SyncV2RemoteCatalogPage {
        guard (1 ... 500).contains(pageSize) else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        let object = try await getJSON(
            path: "v2/works",
            query: [
                URLQueryItem(name: "pageSize", value: String(pageSize)),
                cursor.map { URLQueryItem(name: "cursor", value: $0) }
            ].compactMap(\.self)
        )
        let page = try checkedObject(
            object,
            keys: ["items", "nextCursor", "result"]
        )
        guard page["result"] as? String == "noChanges",
              let rawItems = page["items"] as? [[String: Any]] else {
            throw SyncV2Failure.receiptMismatch
        }
        let items = try rawItems.map { item -> SyncV2RemoteCatalogEntry in
            let item = try checkedObject(item, keys: ["head", "title", "workId"])
            guard let rawWork = item["workId"] as? String,
                  let title = item["title"] as? String else {
                throw SyncV2Failure.receiptMismatch
            }
            return try SyncV2RemoteCatalogEntry(
                workID: WorkID(uuidString: rawWork),
                title: title,
                head: parseHead(item["head"])
            )
        }
        guard page["nextCursor"] is String || page["nextCursor"] is NSNull else {
            throw SyncV2Failure.receiptMismatch
        }
        return SyncV2RemoteCatalogPage(
            items: items,
            nextCursor: page["nextCursor"] as? String
        )
    }

    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        let object = try await getJSON(
            path: "v2/works/\(workID.description)/head",
            query: []
        )
        let response = try checkedObject(object, keys: ["head", "result"])
        guard response["result"] as? String == "noChanges" else {
            throw SyncV2Failure.receiptMismatch
        }
        return try parseHead(response["head"])
    }

    func historyPage(
        workID: WorkID,
        cursor: String?,
        pageSize: Int
    ) async throws -> SyncV2RemoteHistoryPage {
        guard (1 ... 500).contains(pageSize) else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        let object = try await getJSON(
            path: "v2/works/\(workID.description)/history",
            query: [
                URLQueryItem(name: "pageSize", value: String(pageSize)),
                cursor.map { URLQueryItem(name: "cursor", value: $0) }
            ].compactMap(\.self)
        )
        let page = try checkedObject(
            object,
            keys: ["items", "nextCursor", "result"]
        )
        guard page["result"] as? String == "noChanges",
              let rawItems = page["items"] as? [[String: Any]] else {
            throw SyncV2Failure.receiptMismatch
        }
        let formatter = ISO8601DateFormatter()
        let items = try rawItems.map { item -> SyncV2RemoteHistoryEntry in
            try historyEntry(item, formatter: formatter)
        }
        guard page["nextCursor"] is String || page["nextCursor"] is NSNull else {
            throw SyncV2Failure.receiptMismatch
        }
        return SyncV2RemoteHistoryPage(
            items: items,
            nextCursor: page["nextCursor"] as? String
        )
    }

    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        let object = try await getJSON(
            path: "v2/works/\(workID.description)/conflict",
            query: []
        )
        let response = try checkedObject(object, keys: ["conflict", "result"])
        guard response["result"] as? String == "noChanges" else {
            throw SyncV2Failure.receiptMismatch
        }
        guard let rawConflict = response["conflict"] as? [String: Any] else {
            return nil
        }
        let conflict = try checkedObject(
            rawConflict,
            keys: [
                "baseSnapshotId", "conflictId", "localSnapshotId",
                "remoteSnapshotId", "revision", "sourceGeneration", "workId"
            ]
        )
        guard let responseWorkID = conflict["workId"] as? String,
              try WorkID(uuidString: responseWorkID) == workID,
              let id = (conflict["conflictId"] as? String).flatMap(UUID.init),
              let revision = (conflict["revision"] as? NSNumber)?.int64Value,
              let local = conflict["localSnapshotId"] as? String,
              let remote = conflict["remoteSnapshotId"] as? String,
              let generation = (conflict["sourceGeneration"] as? NSNumber)?.int64Value else {
            throw SyncV2Failure.receiptMismatch
        }
        let base: SnapshotID?
        if let rawBase = conflict["baseSnapshotId"] as? String {
            do {
                base = try SnapshotID(rawValue: rawBase)
            } catch {
                throw SyncV2Failure.receiptMismatch
            }
        } else {
            base = nil
        }
        return try SyncV2ConflictProjection(
            conflictID: id,
            revision: revision,
            baseSnapshotID: base,
            localSnapshotID: SnapshotID(rawValue: local),
            remoteSnapshotID: SnapshotID(rawValue: remote),
            sourceGeneration: generation
        )
    }

    private func historyEntry(
        _ rawItem: [String: Any],
        formatter: ISO8601DateFormatter
    ) throws -> SyncV2RemoteHistoryEntry {
        let item = try checkedObject(
            rawItem,
            keys: [
                "createdAt", "occurrenceId", "pinned", "reason", "snapshotId"
            ]
        )
        guard let occurrence = (item["occurrenceId"] as? String).flatMap(UUID.init),
              let snapshotRaw = item["snapshotId"] as? String,
              let reason = item["reason"] as? String,
              let pinned = item["pinned"] as? Bool,
              let createdRaw = item["createdAt"] as? String,
              let createdAt = formatter.date(from: createdRaw) else {
            throw SyncV2Failure.receiptMismatch
        }
        return try SyncV2RemoteHistoryEntry(
            occurrenceID: occurrence,
            snapshotID: SnapshotID(rawValue: snapshotRaw),
            reason: reason,
            pinned: pinned,
            createdAt: createdAt
        )
    }
}
