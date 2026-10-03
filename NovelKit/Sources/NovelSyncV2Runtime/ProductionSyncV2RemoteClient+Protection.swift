import Foundation
import NovelSyncV2
import NovelSyncV2Application

extension ProductionSyncV2RemoteClient {
    /// A 404 alone never means deletion (old servers and missing data use it too).
    func rejectKnownRemoteDeletion(workID: WorkID) async throws {
        let status: [String: Any]
        do {
            status = try await getJSON(path: "v2/protection/\(workID.description)/status", query: [])
        } catch SyncV2Failure.fatal(.remoteDataUnavailable) {
            return
        }
        guard status["workId"] as? String == workID.description,
              status["result"] as? String == "noChanges",
              let deleted = status["deleted"] as? Bool else { throw SyncV2Failure.receiptMismatch }
        if deleted {
            throw SyncV2Failure.fatal(.remoteWorkDeleted)
        }
    }
}

extension ProductionSyncV2RemoteClient {
    func protectedWorks() async throws -> [SyncV2ProtectedWork] {
        var values: [SyncV2ProtectedWork] = []
        var after: String?
        repeat {
            let result = try await getJSON(path: "v2/protection", query: after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
            guard let items = result["items"] as? [[String: Any]] else { throw SyncV2Failure.receiptMismatch }
            for item in items {
                guard let raw = item["workId"] as? String, let title = item["title"] as? String else { throw SyncV2Failure.receiptMismatch }
                try values.append(SyncV2ProtectedWork(workID: WorkID(uuidString: raw), title: title,
                                                      deletedAt: (item["deletedAt"] as? String).flatMap(protectionDate)))
            }
            let next = result["nextAfter"] as? String
            guard next == nil || next != after else { throw SyncV2Failure.receiptMismatch }
            after = next
            try Task.checkCancellation()
        } while after != nil
        return values
    }

    func recoveryPoints(workID: WorkID) async throws -> [SyncV2RecoveryPoint] {
        var points: [SyncV2RecoveryPoint] = []
        var after: Int64 = 0
        while true {
            let page = try await getJSON(path: "v2/protection/\(workID.description)/history",
                                         query: [URLQueryItem(name: "after", value: String(after))])
            guard let items = page["items"] as? [[String: Any]] else { throw SyncV2Failure.receiptMismatch }
            for item in items {
                guard let event = item["eventId"] as? Int64, let raw = item["snapshotId"] as? String,
                      let dateText = item["createdAt"] as? String, let date = protectionDate(dateText) else { throw SyncV2Failure.receiptMismatch }
                try points.append(SyncV2RecoveryPoint(eventID: event, snapshotID: SnapshotID(rawValue: raw), createdAt: date))
            }
            guard let next = page["nextAfter"] as? Int64 else { return points }
            guard next > after else { throw SyncV2Failure.receiptMismatch }
            after = next
            try Task.checkCancellation()
        }
    }

    func recoverWork(workID: WorkID, request recovery: SyncV2RecoveryRequest) async throws {
        let current = try await loadSession()
        var request = URLRequest(url: origin.url.appendingPathComponent("v2/protection/\(workID.description)/recover"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(recovery)
        addHeaders(&request, session: current, binding: SealedCommand.Binding(
            accountFence: current.accountFence, accountId: current.accountID, protocolEpoch: 2,
            serverInstanceId: current.serverInstanceID.uuidString.lowercased()
        ))
        await request.setValue(DeviceLabel.header(deviceLabel()), forHTTPHeaderField: "Fuminiwa-Device-Label")
        // This endpoint accepts ordinary JSON; v2 commands retain their JCS media type.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await requestData(request, session: current)
        try validateSyncResponseHeaders(response)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              httpContentType(response) == mediaType,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["newWorkId"] as? String == recovery.newWorkId.uuidString.lowercased(),
              result["newDocumentId"] as? String == recovery.newDocumentId.uuidString.lowercased(),
              result["operationId"] as? String == recovery.operationId.uuidString.lowercased() else {
            throw SyncV2Failure.fatal(.remoteDataUnavailable)
        }
    }

    private func protectionDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
