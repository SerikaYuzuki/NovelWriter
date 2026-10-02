import Foundation
import NovelSyncV2
import NovelSyncV2Store
import Testing

/// In-process HTTP server with durable, exact-byte command replay. The prepare
/// template and receipt wrapper are compared with Rust canonical_response in
/// prepare_receipt_wire_tests.rs; no production service or credentials are used.
final class NewObjectWireServer: @unchecked Sendable {
    enum EdgeFault { case post, receipt, upload, download, receiptThenReplay }

    struct Reply {
        let status: Int
        let bytes: Data
        var headers = ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache", "X-Fuminiwa-Result": "applied"]
    }

    struct Upload {
        let objectID: ObjectID
        let count: Int
        let capability: String
        let expired: Bool
        var bytes = Data()
    }

    private let lock = NSLock()
    private var replies: [UUID: (SealedCommand, Reply)] = [:]
    private var uploads: [UUID: Upload] = [:]
    private var finalized = Set<ObjectID>()
    private var registered = Set<SnapshotID>()
    private var manifests: [SnapshotID: Data] = [:]
    private var published: V2RemoteHead?
    private var edgeFault: EdgeFault?
    private var edgeFailures = 0
    private var failedCommandBytes: [UUID: Data] = [:]
    private var events: [String] = []
    private var commandIDs: [UUID] = []
    private var expiredPUTs = 0
    private var expireFirstPrepare: Bool
    private let prepareTemplate: [String: Any]

    init(expireFirstPrepare: Bool, edgeFault: EdgeFault? = nil) throws {
        self.edgeFault = edgeFault
        self.expireFirstPrepare = expireFirstPrepare
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("SyncServerV2/tests/fixtures/prepare-object/applied.json"))
        prepareTemplate = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var recordedEvents: [String] {
        lock.withLock { events }
    }

    var recordedCommandIDs: [UUID] {
        lock.withLock { commandIDs }
    }

    var injectedEdgeFailures: Int {
        lock.withLock { edgeFailures }
    }

    private func edgeReply() -> Reply {
        edgeFailures += 1
        edgeFault = nil
        return Reply(status: 502, bytes: Data("<html>Cloudflare: Bad Gateway</html>".utf8), headers: ["Content-Type": "text/html"])
    }

    var expiredUploadAttempts: Int {
        lock.withLock { expiredPUTs }
    }

    func handle(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            let url = try #require(request.url)
            if request.httpMethod == "GET", url.lastPathComponent == "head" {
                let head = try #require(published)
                return try Reply(status: 200, bytes: productionJSON(["head": ["generation": head.generation, "snapshotId": head.snapshotID.rawValue]]))
            }
            if request.httpMethod == "GET", url.lastPathComponent == "download" {
                if url.query?.contains("mode=") == true {
                    return Reply(status: 422, bytes: Data())
                }
                if edgeFault == .download {
                    return edgeReply()
                }
                let head = try #require(published)
                let manifestItems = manifests.map { ["kind": "manifest", "id": $0.key.rawValue, "bytesBase64URL": $0.value.productionBase64URL()] }.sorted { $0["id"]! < $1["id"]! }
                var objects: [ObjectID: Data] = [:]
                for upload in uploads.values where finalized.contains(upload.objectID) && !upload.expired {
                    objects[upload.objectID] = upload.bytes
                }
                let objectItems = objects.filter { $0.value.count <= 256 * 1024 }.map {
                    ["kind": "object", "id": $0.key.rawValue, "bytesBase64URL": $0.value.productionBase64URL()]
                }.sorted { $0["id"]! < $1["id"]! }
                return try Reply(status: 200, bytes: productionJSON(["result": "noChanges", "snapshotId": head.snapshotID.rawValue, "items": manifestItems + objectItems, "nextCursor": NSNull()]))
            }
            if request.httpMethod == "GET", url.path.hasPrefix("/v2/objects/") {
                let upload = try #require(uploads.values.first { $0.objectID.rawValue == url.lastPathComponent && !$0.expired })
                return Reply(status: 200, bytes: upload.bytes, headers: [
                    "Content-Type": "application/octet-stream", "Cache-Control": "no-store", "Pragma": "no-cache",
                    "X-Fuminiwa-Object-Digest": upload.objectID.rawValue, "X-Fuminiwa-Byte-Count": String(upload.bytes.count)
                ])
            }
            if request.httpMethod == "GET" {
                let id = try #require(UUID(uuidString: url.lastPathComponent))
                let (command, original) = try #require(replies[id])
                if command.kind == .prepareObject, edgeFault == .receipt || edgeFault == .receiptThenReplay {
                    let replay = edgeFault == .receiptThenReplay
                    let reply = edgeReply()
                    if replay {
                        edgeFault = .post
                    }
                    return reply
                }
                events.append("receipt")
                return try Reply(status: 200, bytes: Self.receiptEnvelope(original))
            }
            if request.httpMethod == "PUT" {
                if edgeFault == .upload {
                    return edgeReply()
                }
                return try upload(request)
            }
            #expect(request.httpMethod == "POST")
            let command = try SealedCommand.decodeCanonical(requestBody(request))
            events.append(command.commandKind)
            commandIDs.append(command.commandId)
            if let bytes = failedCommandBytes[command.commandId] {
                #expect(bytes == command.canonicalBytes)
            }
            if command.kind == .prepareObject, edgeFault == .post {
                failedCommandBytes[command.commandId] = command.canonicalBytes
                return edgeReply()
            }
            if let (existing, response) = replies[command.commandId] {
                #expect(existing.canonicalBytes == command.canonicalBytes)
                return response
            }
            let response = try commandResponse(command)
            replies[command.commandId] = (command, response)
            return response
        }
    }

    /// Mirror http.rs receipt(): derive metadata from the stored POST body and
    /// embed the exact bytes, without reserializing that body before base64.
    static func receiptEnvelope(_ original: Reply) throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: original.bytes) as? [String: Any])
        let receipt = try #require(object["receipt"] as? [String: Any])
        var wrapper = receipt
        wrapper["canonicalResponseBase64URL"] = original.bytes.productionBase64URL()
        wrapper["originalResponseStatus"] = original.status
        wrapper["originalResult"] = object["result"]
        wrapper["result"] = "noChanges"
        return try productionJSON(wrapper)
    }

    private func commandResponse(_ command: SealedCommand) throws -> Reply {
        let status = [.createWork, .prepareObject].contains(command.kind) ? 201 : 200
        var head: V2RemoteHead?
        switch command.kind {
        case .prepareObject:
            return try prepare(command)
        case .finalizeObject:
            let uploadID = try #require(UUID(uuidString: command.payload.uuid("uploadId")))
            let upload = try #require(uploads[uploadID])
            #expect(upload.bytes.count == upload.count)
            #expect(ObjectID(data: upload.bytes) == upload.objectID)
            #expect(try command.payload.object("objectId") == upload.objectID)
            finalized.insert(upload.objectID)
        case .registerSnapshot:
            let encoded = try #require(command.payload.string("manifestBase64URL"))
            let bytes = try #require(Data(base64URL: encoded))
            let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
            #expect(manifest.entries.allSatisfy { finalized.contains($0.objectId) })
            let id = try command.payload.snapshot("snapshotId")
            registered.insert(id)
            manifests[id] = bytes
        case .publish:
            let snapshot = try command.payload.snapshot("candidateSnapshotId")
            #expect(registered.contains(snapshot))
            head = try V2RemoteHead(snapshotID: snapshot, generation: 1)
            published = head
        case .createWork: break
        default: Issue.record("unexpected command in new-object flow")
        }
        return try Reply(status: status, bytes: productionResponse(command: command, result: .applied, head: head, cloneHead: nil, status: status))
    }

    private func prepare(_ command: SealedCommand) throws -> Reply {
        let objectID = try command.payload.object("objectId")
        let count = try #require(command.payload.integer("byteCount"))
        let id = UUID()
        let expired = expireFirstPrepare
        expireFirstPrepare = false
        let capability = ObjectID(data: Data(id.uuidString.utf8)).rawValue
        uploads[id] = Upload(objectID: objectID, count: Int(count), capability: capability, expired: expired)
        var response = prepareTemplate
        let base = try productionResponse(command: command, result: .applied, head: nil, cloneHead: nil, status: 201)
        let fields = try #require(JSONSerialization.jsonObject(with: base) as? [String: Any])
        for key in ["commandId", "commandKind", "receipt", "result"] {
            response[key] = fields[key]
        }
        response["expiresAt"] = CanonicalTimestamp.string(expired ? Date(timeIntervalSince1970: 0) : Date().addingTimeInterval(900))
            .replacingOccurrences(of: "Z", with: ".383699+00:00")
        response["objectId"] = objectID.rawValue
        response["uploadId"] = id.uuidString.lowercased()
        response["uploadCapability"] = capability
        let bytes = try productionJSON(response)
        #expect(bytes.count == 711)
        return Reply(status: 201, bytes: bytes)
    }

    private func upload(_ request: URLRequest) throws -> Reply {
        let url = try #require(request.url)
        let id = try #require(UUID(uuidString: url.lastPathComponent))
        var upload = try #require(uploads[id])
        #expect(request.value(forHTTPHeaderField: "X-Fuminiwa-Upload-Capability") == upload.capability)
        if upload.expired {
            expiredPUTs += 1
            return Reply(status: 409, bytes: Data(#"{"error":"uploadExpired","result":"parked","retryable":false}"#.utf8))
        }
        let bytes = try requestBody(request)
        #expect(bytes.count <= 8 * 1024 * 1024)
        if upload.count > 8 * 1024 * 1024 {
            #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes \(upload.bytes.count)-\(upload.bytes.count + bytes.count - 1)/\(upload.count)")
        }
        upload.bytes.append(bytes)
        #expect(upload.bytes.count <= upload.count)
        uploads[id] = upload
        events.append("chunk")
        return Reply(status: 204, bytes: Data())
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 {
                break
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
}

final class NewObjectWireProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: NewObjectWireServer?
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let server = try #require(Self.server)
            let reply = try server.handle(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil,
                headerFields: reply.headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
