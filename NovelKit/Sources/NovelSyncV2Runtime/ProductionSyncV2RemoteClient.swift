import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Strict v2 HTTPS adapter. URL paths and wire validation stay outside the
/// application protocol; canonical command/response bytes are never rebuilt.
actor ProductionSyncV2RemoteClient: SyncV2RemoteClient {
    private let origin: ProductionHTTPSOrigin
    private let vault: any AuthSessionVault
    private let clientVersion: String
    private let session: URLSession
    private let mediaType = "application/vnd.fuminiwa.sync.v2+jcs"

    init(
        origin: ProductionHTTPSOrigin,
        vault: any AuthSessionVault,
        clientVersion: String = "0.0.0",
        clientPlatform: AuthClientPlatform = .macos,
        session: URLSession? = nil
    ) {
        self.origin = origin
        self.vault = vault
        self.clientVersion = clientVersion
        _ = clientPlatform
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        guard let session = try await vault.load() else { throw SyncV2Failure.authenticationRequired }
        guard session.syncProtocolEpoch == 2 else { throw SyncV2Failure.accountFenceChanged }
        switch operation {
        case let .upload(transfer):
            return try await upload(transfer, session: session)
        case let .command(planned):
            let command = planned.command
            guard command.binding.accountId == session.accountID,
                  command.binding.accountFence == session.accountFence,
                  command.binding.protocolEpoch == 2,
                  command.binding.serverInstanceId == session.serverInstanceID.uuidString.lowercased() else {
                throw SyncV2Failure.accountFenceChanged
            }
            let receipt = try await send(command, session: session)
            return try await .command(
                receipt: receipt,
                remoteInbox: planned.kind == .publish &&
                    (receipt.result == .noChanges || receipt.result == .conflictPending)
                    ? inbox(command: command, receipt: receipt, session: session)
                    : nil
            )
        }
    }

    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox {
        guard let session = try await vault.load() else { throw SyncV2Failure.authenticationRequired }
        let binding = SealedCommand.Binding(accountFence: session.accountFence, accountId: session.accountID, protocolEpoch: 2, serverInstanceId: session.serverInstanceID.uuidString.lowercased())
        var request = URLRequest(url: origin.url.appendingPathComponent("v2/works/\(workID.description)/head"))
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: binding)
        let (data, response) = try await requestData(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headObject = object["head"] as? [String: Any],
              let generation = (headObject["generation"] as? NSNumber)?.int64Value,
              let raw = headObject["snapshotId"] as? String else { throw SyncV2Failure.fatal(.unexpected) }
        let head = try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: raw), generation: generation)
        let snapshots = try await fetchSnapshot(workID: workID, id: head.snapshotID, session: session, seen: [])
        return SyncV2RemoteInbox(inboxID: UUID(), workID: workID, headSnapshotID: head.snapshotID, snapshots: snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0, expectedRemoteHead: head)
    }

    private func send(_ command: SealedCommand, session: FuminiwaSession) async throws -> SyncV2ReceiptReadback {
        let path: String
        switch command.commandKind {
        case "createWork": path = "v2/works"
        case "prepareObject": path = "v2/objects/prepare"
        case "finalizeObject": path = "v2/objects/finalize"
        case "registerSnapshot": path = "v2/snapshots/register"
        case "publish": path = try "v2/works/\(command.workID.description)/publish"
        case "resolveDevice", "resolveServer", "cloneWork": path = try "v2/works/\(command.workID.description)/conflict/resolve"
        case "restore": path = try "v2/works/\(command.workID.description)/restore"
        default: throw SyncV2Failure.fatal(.unsupportedCommand)
        }
        var request = URLRequest(url: origin.url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = command.canonicalBytes
        addHeaders(&request, session: session, binding: command.binding)
        let (data, response) = try await requestData(request)
        return try decode(data: data, response: response, command: command)
    }

    private func upload(_ transfer: SyncV2UploadTransfer, session: FuminiwaSession) async throws -> SyncV2RemoteExecution {
        var request = URLRequest(url: origin.url.appendingPathComponent("v2/uploads/\(transfer.uploadID.uuidString.lowercased())"))
        request.httpMethod = "PUT"
        request.httpBody = transfer.exactBytes
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Fuminiwa-Client-Version")
        request.setValue(transfer.capability, forHTTPHeaderField: "X-Fuminiwa-Upload-Capability")
        addScope(&request, accountID: session.accountID, accountFence: session.accountFence, server: session.serverInstanceID.uuidString.lowercased())
        let (data, response) = try await requestData(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204,
              http.value(forHTTPHeaderField: "X-Fuminiwa-Result") == "applied",
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache" else {
            if let http = response as? HTTPURLResponse, http.statusCode == 409 {
                throw typedUploadFailure(data: data)
            }
            throw mapStatus((response as? HTTPURLResponse)?.statusCode ?? 599)
        }
        return .upload(SyncV2UploadCompletion(transferID: transfer.transferID, uploadID: transfer.uploadID, objectID: transfer.objectID, acknowledgedByteCount: transfer.exactBytes.count))
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw SyncV2Failure.retryable(.lostResponse) }
    }

    private func decode(data: Data, response: URLResponse, command: SealedCommand) throws -> SyncV2ReceiptReadback {
        guard let http = response as? HTTPURLResponse else { throw SyncV2Failure.retryable(.lostResponse) }
        guard http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init) == mediaType else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        guard [200, 201, 409].contains(http.statusCode) else { throw mapStatus(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandID = UUID(uuidString: object["commandId"] as? String ?? ""), commandID == command.commandId,
              object["commandKind"] as? String == command.commandKind,
              let result = SyncV2RemoteResult(rawValue: object["result"] as? String ?? ""),
              let receipt = object["receipt"] as? [String: Any],
              let digestRaw = receipt["requestDigest"] as? String,
              let readBack = receipt["readBack"] as? [String: Any] else { throw SyncV2Failure.receiptMismatch }
        let digest: ObjectID
        do { digest = try ObjectID(rawValue: digestRaw) }
        catch { throw SyncV2Failure.receiptMismatch }
        let head = try parseHead(object["head"])
        let predicates = SyncV2ReadBackPredicates(
            accountMatched: readBack["accountMatched"] as? Bool == true,
            commandDigestMatched: readBack["commandDigestMatched"] as? Bool == true,
            resourceMatched: readBack["resourceMatched"] as? Bool == true,
            headMatched: readBack["headMatched"] as? Bool == true,
            stateMatched: readBack["stateMatched"] as? Bool == true
        )
        guard predicates.allVerified else { throw SyncV2Failure.receiptMismatch }
        let conflict: SyncV2ConflictProjection?
        if result == .conflictPending {
            guard let id = UUID(uuidString: object["conflictId"] as? String ?? ""),
                  let revision = (object["conflictRevision"] as? NSNumber)?.int64Value,
                  let head, let generation = (object["sourceGeneration"] as? NSNumber)?.int64Value else { throw SyncV2Failure.receiptMismatch }
            conflict = SyncV2ConflictProjection(conflictID: id, revision: revision, baseSnapshotID: nil, localSnapshotID: command.sourceSnapshotId, remoteSnapshotID: head.snapshotID, sourceGeneration: generation)
        } else {
            conflict = nil
        }
        return SyncV2ReceiptReadback(commandID: commandID, requestDigest: digest, responseStatus: http.statusCode, canonicalResponse: data, predicates: predicates, result: result, conflict: conflict, remoteHead: head)
    }

    private func inbox(command: SealedCommand, receipt: SyncV2ReceiptReadback, session: FuminiwaSession) async throws -> SyncV2RemoteInbox? {
        guard let head = receipt.remoteHead else { return nil }
        let workID = try command.workID
        let snapshots = try await fetchSnapshot(workID: workID, id: head.snapshotID, session: session, seen: [])
        return try SyncV2RemoteInbox(inboxID: UUID(), workID: workID, headSnapshotID: head.snapshotID, snapshots: snapshots, expectedCurrentSnapshotID: command.sourceSnapshotId, expectedLocalGeneration: command.sourceGeneration, expectedRemoteHead: SyncV2RemoteHead(snapshotID: head.snapshotID, generation: head.generation))
    }

    private func fetchSnapshot(workID: WorkID, id: SnapshotID, session: FuminiwaSession, seen: Set<SnapshotID>) async throws -> [EncodedSnapshot] {
        guard !seen.contains(id), seen.count < 128 else { throw SyncV2Failure.fatal(.invalidLocalState) }
        var request = URLRequest(url: origin.url.appendingPathComponent("v2/snapshots/\(id.rawValue)/manifest"))
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: SealedCommand.Binding(accountFence: session.accountFence, accountId: session.accountID, protocolEpoch: 2, serverInstanceId: session.serverInstanceID.uuidString.lowercased()))
        let (data, response) = try await requestData(request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init) == mediaType,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["manifestBase64URL"] as? String,
              let digestRaw = object["manifestBytesDigest"] as? String,
              let bytes = Data(base64URL: raw),
              SnapshotID(data: bytes) == id,
              ObjectID(data: bytes).rawValue == digestRaw,
              object["snapshotId"] as? String == id.rawValue,
              object["result"] as? String == "noChanges" else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            var objectRequest = URLRequest(url: origin.url.appendingPathComponent("v2/objects/\(entry.objectId.rawValue)"))
            objectRequest.httpMethod = "GET"
            addHeaders(&objectRequest, session: session, binding: SealedCommand.Binding(accountFence: session.accountFence, accountId: session.accountID, protocolEpoch: 2, serverInstanceId: session.serverInstanceID.uuidString.lowercased()))
            let (rawObject, objectResponse) = try await requestData(objectRequest)
            guard let objectHTTP = objectResponse as? HTTPURLResponse,
                  objectHTTP.statusCode == 200,
                  objectHTTP.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
                  objectHTTP.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
                  objectHTTP.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init) == "application/octet-stream",
                  objectHTTP.value(forHTTPHeaderField: "X-Fuminiwa-Object-Digest") == entry.objectId.rawValue,
                  Int(objectHTTP.value(forHTTPHeaderField: "X-Fuminiwa-Byte-Count") ?? "") == rawObject.count,
                  rawObject.count == entry.byteCount,
                  ObjectID(data: rawObject) == entry.objectId else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
            objects[entry.objectId] = rawObject
        }
        var result: [EncodedSnapshot] = []
        for parent in manifest.parentSnapshotIds {
            result += try await fetchSnapshot(workID: workID, id: parent, session: session, seen: seen.union([id]))
        }
        result.append(EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: objects))
        return result
    }

    private func addHeaders(_ request: inout URLRequest, session: FuminiwaSession, binding: SealedCommand.Binding) {
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Fuminiwa-Client-Version")
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(mediaType, forHTTPHeaderField: "Accept")
        addScope(&request, accountID: binding.accountId, accountFence: binding.accountFence, server: binding.serverInstanceId)
    }

    private func addScope(_ request: inout URLRequest, accountID: String, accountFence: String, server: String) {
        _ = accountID
        request.setValue(server, forHTTPHeaderField: "X-Fuminiwa-Server-Instance")
        request.setValue("2", forHTTPHeaderField: "X-Fuminiwa-Protocol-Epoch")
        request.setValue(accountFence, forHTTPHeaderField: "X-Fuminiwa-Account-Fence")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    }

    private func parseHead(_ value: Any?) throws -> SyncV2RemoteHead? {
        guard let value else { return nil }
        guard let head = value as? [String: Any], let generation = (head["generation"] as? NSNumber)?.int64Value, let raw = head["snapshotId"] as? String else { throw SyncV2Failure.receiptMismatch }
        return try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: raw), generation: generation)
    }

    private func mapStatus(_ status: Int) -> SyncV2Failure {
        switch status { case 401: .authenticationRequired; case 403: .accountFenceChanged; case 408, 429, 500 ... 599: .retryable(.serverUnavailable); default: .fatal(.unexpected) }
    }

    private func typedUploadFailure(data: Data) -> SyncV2Failure {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String else {
            return .retryable(.serverUnavailable)
        }
        switch code {
        case "uploadExpired": return .retryable(.uploadExpired)
        case "uploadCapabilityMismatch", "objectDigestMismatch": return .fatal(.unexpected)
        default: return .retryable(.serverUnavailable)
        }
    }
}

private extension SealedCommand {
    var workID: WorkID {
        get throws {
            guard let object = try JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any], let raw = (object["workId"] as? String) ?? (object["sourceWorkId"] as? String) else { throw SyncV2Failure.receiptMismatch }
            return try WorkID(uuidString: raw)
        }
    }
}

private extension Data {
    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
