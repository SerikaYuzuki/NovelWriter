import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct ResponseEnvelope {
    let object: [String: Any]
    let commandID: UUID
    let result: SyncV2RemoteResult
    let digest: ObjectID
    let readBack: [String: Any]
}

extension ProductionSyncV2RemoteClient {
    func send(
        _ command: SealedCommand,
        session: FuminiwaSession
    ) async throws -> SyncV2ReceiptReadback {
        let path: String
        switch command.commandKind {
        case "createWork":
            path = "v2/works"
        case "prepareObject":
            path = "v2/objects/prepare"
        case "finalizeObject":
            path = "v2/objects/finalize"
        case "registerSnapshot":
            path = "v2/snapshots/register"
        case "publish":
            path = try "v2/works/\(remoteClientWorkID(for: command).description)/publish"
        case "resolveDevice", "resolveServer", "cloneWork":
            path = try "v2/works/\(remoteClientWorkID(for: command).description)/conflict/resolve"
        case "restore":
            path = try "v2/works/\(remoteClientWorkID(for: command).description)/restore"
        default:
            throw SyncV2Failure.fatal(.unsupportedCommand)
        }
        var request = URLRequest(url: origin.url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = command.canonicalBytes
        addHeaders(&request, session: session, binding: command.binding)
        let (data, response) = try await requestData(request)
        return try decode(data: data, response: response, command: command)
    }

    func getJSON(
        path: String,
        query: [URLQueryItem]
    ) async throws -> [String: Any] {
        guard let sessionValue = try await vault.load() else {
            throw SyncV2Failure.authenticationRequired
        }
        var components = URLComponents(
            url: origin.url.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let binding = SealedCommand.Binding(
            accountFence: sessionValue.accountFence,
            accountId: sessionValue.accountID,
            protocolEpoch: 2,
            serverInstanceId: sessionValue.serverInstanceID.uuidString.lowercased()
        )
        addHeaders(&request, session: sessionValue, binding: binding)
        let (data, response) = try await requestData(request)
        let contentType = httpContentType(response)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              contentType == mediaType,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw mapStatus((response as? HTTPURLResponse)?.statusCode ?? 599)
        }
        return object
    }

    func upload(
        _ transfer: SyncV2UploadTransfer,
        session: FuminiwaSession
    ) async throws -> SyncV2RemoteExecution {
        let url = origin.url.appendingPathComponent(
            "v2/uploads/\(transfer.uploadID.uuidString.lowercased())"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = transfer.exactBytes
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(session.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            clientVersion,
            forHTTPHeaderField: "X-Fuminiwa-Client-Version"
        )
        request.setValue(
            transfer.capability,
            forHTTPHeaderField: "X-Fuminiwa-Upload-Capability"
        )
        addScope(
            &request,
            accountID: session.accountID,
            accountFence: session.accountFence,
            server: session.serverInstanceID.uuidString.lowercased()
        )
        let (data, response) = try await requestData(request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 204,
              http.value(forHTTPHeaderField: "X-Fuminiwa-Result") == "applied",
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache" else {
            if let http = response as? HTTPURLResponse, http.statusCode == 409 {
                throw typedUploadFailure(data: data)
            }
            throw mapStatus((response as? HTTPURLResponse)?.statusCode ?? 599)
        }
        return .upload(
            SyncV2UploadCompletion(
                transferID: transfer.transferID,
                uploadID: transfer.uploadID,
                objectID: transfer.objectID,
                acknowledgedByteCount: transfer.exactBytes.count
            )
        )
    }

    func requestData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SyncV2Failure.retryable(.lostResponse)
        }
    }

    func addHeaders(
        _ request: inout URLRequest,
        session: FuminiwaSession,
        binding: SealedCommand.Binding
    ) {
        request.setValue(
            "Bearer \(session.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            clientVersion,
            forHTTPHeaderField: "X-Fuminiwa-Client-Version"
        )
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(mediaType, forHTTPHeaderField: "Accept")
        addScope(
            &request,
            accountID: binding.accountId,
            accountFence: binding.accountFence,
            server: binding.serverInstanceId
        )
    }

    func parseHead(_ value: Any?) throws -> SyncV2RemoteHead? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        guard let rawHead = value as? [String: Any] else {
            throw SyncV2Failure.receiptMismatch
        }
        let head = try checkedObject(rawHead, keys: ["generation", "snapshotId"])
        guard let generation = (head["generation"] as? NSNumber)?.int64Value,
              let raw = head["snapshotId"] as? String else {
            throw SyncV2Failure.receiptMismatch
        }
        return try SyncV2RemoteHead(
            snapshotID: SnapshotID(rawValue: raw),
            generation: generation
        )
    }

    func checkedObject(
        _ object: [String: Any],
        keys: [String]
    ) throws -> [String: Any] {
        guard Set(object.keys) == Set(keys) else {
            throw SyncV2Failure.receiptMismatch
        }
        return object
    }

    private func decode(
        data: Data,
        response: URLResponse,
        command: SealedCommand
    ) throws -> SyncV2ReceiptReadback {
        guard let http = response as? HTTPURLResponse else {
            throw SyncV2Failure.retryable(.lostResponse)
        }
        let contentType = httpContentType(response)
        guard http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              contentType == mediaType else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        guard [200, 201, 409].contains(http.statusCode) else {
            throw mapStatus(http.statusCode)
        }
        let envelope = try decodeResponseEnvelope(data: data, command: command)
        let head = try parseHead(envelope.object["head"])
        let predicates = SyncV2ReadBackPredicates(
            accountMatched: envelope.readBack["accountMatched"] as? Bool == true,
            commandDigestMatched: envelope.readBack["commandDigestMatched"] as? Bool == true,
            resourceMatched: envelope.readBack["resourceMatched"] as? Bool == true,
            headMatched: envelope.readBack["headMatched"] as? Bool == true,
            stateMatched: envelope.readBack["stateMatched"] as? Bool == true
        )
        guard predicates.allVerified else {
            throw SyncV2Failure.receiptMismatch
        }
        let conflict = try makeConflict(
            result: envelope.result,
            object: envelope.object,
            head: head,
            command: command
        )
        return SyncV2ReceiptReadback(
            commandID: envelope.commandID,
            requestDigest: envelope.digest,
            responseStatus: http.statusCode,
            canonicalResponse: data,
            predicates: predicates,
            result: envelope.result,
            conflict: conflict,
            remoteHead: head
        )
    }

    private func decodeResponseEnvelope(
        data: Data,
        command: SealedCommand
    ) throws -> ResponseEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandID = UUID(uuidString: object["commandId"] as? String ?? ""),
              commandID == command.commandId,
              object["commandKind"] as? String == command.commandKind,
              let result = SyncV2RemoteResult(rawValue: object["result"] as? String ?? ""),
              let receipt = object["receipt"] as? [String: Any],
              let digestRaw = receipt["requestDigest"] as? String,
              let readBack = receipt["readBack"] as? [String: Any] else {
            throw SyncV2Failure.receiptMismatch
        }
        let digest: ObjectID
        do {
            digest = try ObjectID(rawValue: digestRaw)
        } catch {
            throw SyncV2Failure.receiptMismatch
        }
        guard digest == command.requestDigest else {
            throw SyncV2Failure.receiptMismatch
        }
        return ResponseEnvelope(
            object: object,
            commandID: commandID,
            result: result,
            digest: digest,
            readBack: readBack
        )
    }

    private func makeConflict(
        result: SyncV2RemoteResult,
        object: [String: Any],
        head: SyncV2RemoteHead?,
        command: SealedCommand
    ) throws -> SyncV2ConflictProjection? {
        guard result == .conflictPending else {
            return nil
        }
        guard let id = UUID(uuidString: object["conflictId"] as? String ?? ""),
              let revision = (object["conflictRevision"] as? NSNumber)?.int64Value,
              let head,
              let generation = (object["sourceGeneration"] as? NSNumber)?.int64Value else {
            throw SyncV2Failure.receiptMismatch
        }
        let baseSnapshotID = try publishExpectedRemoteHeadSnapshotID(command)
        return SyncV2ConflictProjection(
            conflictID: id,
            revision: revision,
            baseSnapshotID: baseSnapshotID,
            localSnapshotID: command.sourceSnapshotId,
            remoteSnapshotID: head.snapshotID,
            sourceGeneration: generation
        )
    }

    private func publishExpectedRemoteHeadSnapshotID(
        _ command: SealedCommand
    ) throws -> SnapshotID? {
        guard command.commandKind == "publish" else {
            return nil
        }
        guard let payload = try JSONSerialization.jsonObject(with: command.payloadBytes)
            as? [String: Any],
            let expected = payload["expectedRemoteHead"] else {
            throw SyncV2Failure.receiptMismatch
        }
        if expected is NSNull {
            return nil
        }
        guard let head = expected as? [String: Any],
              Set(head.keys) == ["generation", "snapshotId"],
              head["generation"] is NSNumber,
              let rawSnapshotID = head["snapshotId"] as? String else {
            throw SyncV2Failure.receiptMismatch
        }
        return try SnapshotID(rawValue: rawSnapshotID)
    }

    private func addScope(
        _ request: inout URLRequest,
        accountID: String,
        accountFence: String,
        server: String
    ) {
        _ = accountID
        request.setValue(server, forHTTPHeaderField: "X-Fuminiwa-Server-Instance")
        request.setValue("2", forHTTPHeaderField: "X-Fuminiwa-Protocol-Epoch")
        request.setValue(accountFence, forHTTPHeaderField: "X-Fuminiwa-Account-Fence")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    }

    private func mapStatus(_ status: Int) -> SyncV2Failure {
        switch status {
        case 401:
            .authenticationRequired
        case 403:
            .accountFenceChanged
        case 408, 429, 500 ... 599:
            .retryable(.serverUnavailable)
        default:
            .fatal(.unexpected)
        }
    }

    private func typedUploadFailure(data: Data) -> SyncV2Failure {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                return .retryable(.serverUnavailable)
            }
            object = decoded
        } catch {
            return .retryable(.serverUnavailable)
        }
        guard let code = object["code"] as? String else {
            return .retryable(.serverUnavailable)
        }
        switch code {
        case "uploadExpired":
            return .retryable(.uploadExpired)
        case "uploadCapabilityMismatch", "objectDigestMismatch":
            return .fatal(.unexpected)
        default:
            return .retryable(.serverUnavailable)
        }
    }
}

func httpContentType(_ response: URLResponse) -> String? {
    (response as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Content-Type")?
        .split(separator: ";")
        .first
        .map(String.init)
}
