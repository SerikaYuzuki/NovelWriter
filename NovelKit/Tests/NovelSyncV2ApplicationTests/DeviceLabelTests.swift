import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

@Suite(.serialized)
struct DeviceLabelTests {
    @Test func normalizationLimitsAndPrivacyDefaults() {
        for kind in ["Mac", "iPhone", "iPad"] {
            #expect(DeviceLabel.current(nil, defaultLabel: kind) == kind)
            #expect(DeviceLabel.current("", defaultLabel: kind) == kind)
            #expect(DeviceLabel.current("仕事用Mac", defaultLabel: kind) == "仕事用Mac")
        }
        #expect(DeviceLabel.validated("e\u{301}") == "é")
        #expect(DeviceLabel.validated(String(repeating: "😀", count: 40)) != nil)
        #expect(DeviceLabel.validated(String(repeating: "a", count: 41)) == nil)
        #expect(DeviceLabel.setting(String(repeating: "か\u{3099}", count: 41)) == String(repeating: "が", count: 40))
        for invalid in ["", "\n", "\r", "\u{0}", "\u{85}", "\u{2028}", "\u{2029}"] {
            #expect(DeviceLabel.validated(invalid) == nil)
        }
        #expect(DeviceLabel.header("仕事用Mac") == "%E4%BB%95%E4%BA%8B%E7%94%A8Mac")
    }

    @Test func historyLabelsAndCursorRoundTrip() async throws {
        let remote = HistoryProjectionRemote()
        let state = InMemorySyncV2RuntimeState(account: nil)
        let app = try applicationTestApp(state: state, remote: remote)
        let id = try SnapshotID(rawValue: String(repeating: "a", count: 64))
        let entries = (0 ..< 3).map {
            SyncV2RemoteHistoryEntry(occurrenceID: UUID(), snapshotID: id, reason: "publish", pinned: true,
                                     createdAt: Date(timeIntervalSince1970: Double($0)), deviceLabel: $0 == 0 ? nil : "仕事用Mac")
        }
        await remote.set(entries: entries)
        let work = WorkID(UUID())
        _ = try await app.checkpoint(workID: work, document: applicationTestDocument(title: "local"),
                                     reason: .explicit, documentCreatedAt: applicationTestCreatedAt)
        let first = try await app.historyPage(workID: work, pageSize: 2)
        let cursor = try #require(first.nextCursor)
        #expect(cursor.utf8.count < 4000)
        let second = try await app.historyPage(workID: work, cursor: cursor, pageSize: 2)
        var items = first.items + second.items
        if let next = second.nextCursor {
            items += try await app.historyPage(workID: work, cursor: next, pageSize: 2).items
        }
        let labels = items.map { $0.displayDeviceLabel(currentLabel: "iPhone") }
        #expect(labels.count(where: { $0 == "仕事用Mac" }) == 2)
        #expect(labels.count(where: { $0 == "別の端末" }) == 1)
        let local = SyncV2HistoryItem(occurrenceID: UUID(), snapshotID: id, reason: "autosaveLeaf", pinned: false,
                                      localGeneration: 1, createdAt: Date(), source: .local,
                                      localAvailability: .available, onlineAvailability: .unavailable)
        #expect(local.displayDeviceLabel(currentLabel: "仕事用Mac") == "仕事用Mac")
        // Older encoded entries omit the optional field and still decode.
        let data = try #require(Data(base64Encoded: cursor))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var pending = try #require(object["remoteItems"] as? [[String: Any]])
        for index in pending.indices {
            pending[index].removeValue(forKey: "deviceLabel")
        }
        object["remoteItems"] = pending
        let oldCursor = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        _ = try await app.historyPage(workID: work, cursor: oldCursor, pageSize: 2)
    }

    @Test(arguments: [400, 404, 405, 422, 401, 403, 429, 503])
    func optInFallbackIsBounded(status: Int) async throws {
        for endpoint in ["history", "conflict"] {
            let (client, session) = try client()
            _ = session
            LabelURLProtocol.reset(status: status, endpoint: endpoint)
            let work = WorkID(UUID())
            do {
                if endpoint == "history" {
                    _ = try await client.historyPage(workID: work, cursor: nil, pageSize: 1)
                } else {
                    _ = try await client.remoteConflict(workID: work)
                }
            } catch {}
            let requests = LabelURLProtocol.requests()
            let fallback = [400, 404, 405, 422].contains(status)
            // Auth failures never remove opt-in; this vault-only fixture cannot refresh.
            #expect(requests.count == (fallback ? 2 : 1))
            #expect(requests.first?.url?.query?.contains("include=deviceLabel") == true)
            if fallback {
                #expect(requests.last?.url?.query?.contains("include=") != true)
            } else {
                #expect(requests.allSatisfy { $0.url?.query?.contains("include=deviceLabel") == true })
            }
        }
    }

    @Test func optInDecodesNewAndIgnoredHeaderServerShapes() async throws {
        let (client, _) = try client()
        let work = WorkID(UUID())
        for includesLabel in [true, false] {
            LabelURLProtocol.reset(status: 200, endpoint: "history", includesLabel: includesLabel)
            let page = try await client.historyPage(workID: work, cursor: nil, pageSize: 1)
            #expect(page.items.first?.deviceLabel == (includesLabel ? "仕事用Mac" : nil))
            #expect(LabelURLProtocol.requests().count == 1)
            LabelURLProtocol.reset(status: 200, endpoint: "conflict", includesLabel: includesLabel)
            let conflict = try #require(await client.remoteConflict(workID: work))
            #expect(conflict.remoteDeviceLabel == (includesLabel ? "仕事用Mac" : nil))
        }
    }

    @Test func onlyHistoryCommandsCarryHeaderAndCanonicalBytesAreIdentical() async throws {
        let (client, session) = try client()
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            root.deleteLastPathComponent()
        }
        root.appendPathComponent("docs/sync/v2/fixtures/canonical")
        let hashData = try Data(contentsOf: root.appendingPathComponent("command-hashes.json"))
        let hashes = try #require(JSONSerialization.jsonObject(with: hashData) as? [String: Any])
        for row in try #require(hashes["commands"] as? [[String: Any]]) {
            let bytes = try Data(contentsOf: root.appendingPathComponent(#require(row["file"] as? String)))
            let command = try SealedCommand.decodeCanonical(bytes)
            LabelURLProtocol.reset(status: 503, endpoint: "command")
            do { _ = try await client.send(command, session: session) } catch {}
            let sent = try #require(LabelURLProtocol.requests().first)
            #expect(sent.httpBody == bytes)
            #expect(command.requestDigest.rawValue == row["requestDigest"] as? String)
            let expected = [.publish, .resolveDevice, .resolveServer, .restore, .cloneWork].contains(command.kind)
            let expectedHeader = expected ? DeviceLabel.header("仕事用Mac") : nil
            #expect(sent.value(forHTTPHeaderField: "Fuminiwa-Device-Label") == expectedHeader)
        }
    }

    private func client() throws -> (ProductionSyncV2RemoteClient, FuminiwaSession) {
        let binding = AuthSessionBinding(serverInstanceID: UUID(), syncProtocolEpoch: 2, accountID: "fixture-account",
                                         accountAuthEpoch: 1, accountFence: "fixture-fence", sessionID: UUID())
        let session = FuminiwaSession(binding: binding, tokens: AuthSessionTokens(
            accessToken: "fixture-token", accessTokenExpiresAt: Date().addingTimeInterval(900),
            refreshToken: "fixture-refresh", refreshTokenExpiresAt: Date().addingTimeInterval(900), refreshGeneration: 1
        ), receipt: AuthReceipt(commandKind: "rotateRefreshToken", operationID: UUID(), replayUntil: Date().addingTimeInterval(900)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LabelURLProtocol.self]
        return try (ProductionSyncV2RemoteClient(origin: ProductionHTTPSOrigin(url: #require(URL(string: "https://device-label.test"))),
                                                 vault: InMemoryAuthSessionVault(session: session), session: URLSession(configuration: configuration),
                                                 deviceLabel: { "仕事用Mac" }), session)
    }
}

private class LabelURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var captured: [URLRequest] = []
    private nonisolated(unsafe) static var status = 200
    private nonisolated(unsafe) static var endpoint = "history"
    private nonisolated(unsafe) static var includesLabel = true

    static func reset(status: Int, endpoint: String, includesLabel: Bool = true) {
        lock.withLock { captured = []; self.status = status; self.endpoint = endpoint; self.includesLabel = includesLabel }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { captured }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            capturedRequest.httpBody = data
        }
        let (status, endpoint, label) = Self.lock.withLock {
            Self.captured.append(capturedRequest)
            let first = Self.captured.count == 1 || Self.status == 401
            return (first ? Self.status : 200, Self.endpoint, Self.includesLabel)
        }
        let body: String
        if endpoint == "conflict" {
            let work = request.url!.pathComponents.dropLast().last!
            let conflict: [String: Any] = [
                "baseSnapshotId": NSNull(), "conflictId": "00000000-0000-4000-8000-000000000001",
                "localSnapshotId": String(repeating: "b", count: 64), "remoteSnapshotId": String(repeating: "a", count: 64),
                "revision": 1, "sourceGeneration": 1, "workId": work
            ]
            var labelled = conflict
            if label {
                labelled["remoteDeviceLabel"] = "仕事用Mac"
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["conflict": labelled, "result": "noChanges"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData))
                return
            }
            body = String(decoding: data, as: UTF8.self)
        } else {
            let metadata = label ? #", "deviceLabel":"仕事用Mac""# : ""
            body = [
                #"{"items":[{"createdAt":"2026-10-04T00:00:00Z","occurrenceId":"00000000-0000-4000-8000-000000000001","#,
                #""pinned":true,"reason":"publish","snapshotId":""#,
                String(repeating: "a", count: 64), "\"", metadata,
                #"}],"nextCursor":null,"result":"noChanges"}"#
            ].joined()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [
            "Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
