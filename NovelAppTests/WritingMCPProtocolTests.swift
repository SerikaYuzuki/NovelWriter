import Foundation
@testable import FUMINIWA
import NovelCore
import NovelWritingSupport
import Testing

@MainActor
struct WritingMCPProtocolTests {
    private let port: UInt16 = 55907
    private let client = UUID()

    @Test(arguments: WritingMCPVersion.allCases)
    func revisionsListAndReadCurrentEpisode(version: WritingMCPVersion) async throws {
        let document = NovelDocument.newDocument(title: "合成作品")
        let episode = document.chapters[0].episodes[0].id
        let host = makeHost(document, episode: episode)
        if version != .july2026 {
            let initialized = try await send(
                request("initialize", params: ["protocolVersion": version.rawValue]),
                version: version
            )
            #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == version.rawValue)
            #expect(try await responseBody(request("notifications/initialized"), version: version) == nil)
        }
        let listing = try await send(request("tools/list", version: version), version: version)
        let result = try #require(listing["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["read_work", "edit_work", "undo_edit", "read_thumbnail", "set_thumbnail", "remove_thumbnail"])
        #expect((tools[0]["description"] as? String)?.contains("サムネイル画像") == true)
        #expect((tools[1]["description"] as? String)?.contains("サムネイル画像") == true)
        if version == .july2026 {
            #expect(result["resultType"] as? String == "complete")
            #expect(result["ttlMs"] as? Int == 0)
            #expect(result["cacheScope"] as? String == "private")
            #expect((result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] != nil)
        } else {
            #expect(result["resultType"] == nil)
            #expect(result["ttlMs"] == nil)
        }
        let read = request(
            "tools/call",
            params: ["name": "read_work", "arguments": ["paths": [["title"]]]],
            version: version
        )
        let output = try await toolOutput(send(read, version: version, host: host))
        #expect(output["currentEpisodeId"] as? String == episode.rawValue.uuidString.lowercased())
        #expect(output["workId"] is String)
        #expect(output["sessionId"] as? String == "synthetic-session")
        let noEpisode = try await toolOutput(send(read, version: version, host: makeHost(document, episode: nil)))
        #expect(noEpisode["currentEpisodeId"] is NSNull)
    }

    @Test func modernDiscoveryAndPingNeedNoInitializationOrClientInfo() async throws {
        let response = try await send(request("server/discover", version: .july2026), version: .july2026)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["supportedVersions"] as? [String] == WritingMCPVersion.supported)
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(result["instructions"] is String)
        #expect(result["resultType"] as? String == "complete")
        #expect(result["ttlMs"] as? Int == 0)
        #expect(result["cacheScope"] as? String == "private")
        let ping = try await send(request("ping", version: .july2026), version: .july2026)
        #expect((ping["result"] as? [String: Any])?["resultType"] as? String == "complete")
    }

    @Test func routingHeaderFailuresNeverDispatch() throws {
        let call = request("tools/call", params: ["name": "read_work"], version: .july2026)
        let good = headers(call, version: .july2026)
        for field in ["mcp-protocol-version", "mcp-method", "mcp-name"] {
            var missing = good; missing[field] = nil
            try expectRejected(call, headers: missing, status: 400, code: -32020)
            var mismatch = good; mismatch[field] = field == "mcp-protocol-version" ? "2025-11-25" : "different"
            try expectRejected(call, headers: mismatch, status: 400, code: -32020)
        }
        for invalid in ["=?base64?not-base64?=", "=?base64?/w==?=", "read_話", "read\u{7F}work"] {
            var malformed = good; malformed["mcp-name"] = invalid
            try expectRejected(call, headers: malformed, status: 400, code: -32020)
        }
        var encoded = good
        encoded["mcp-name"] = "=?base64?" + Data("read_work".utf8).base64EncodedString() + "?="
        guard case .accepted = try parse(call, headers: encoded) else { Issue.record("Encoded name was rejected"); return }
        // Name headers on other methods must also agree with their body source if supplied.
        var unexpected = headers(request("tools/list", version: .july2026), version: .july2026)
        unexpected["mcp-name"] = "read_work"
        try expectRejected(request("tools/list", version: .july2026), headers: unexpected, status: 400, code: -32020)
    }

    @Test func metadataVersionAndUnknownMethodErrors() async throws {
        let good = request("tools/list", version: .july2026)
        for key in ["io.modelcontextprotocol/protocolVersion", "io.modelcontextprotocol/clientCapabilities"] {
            var broken = good, params = try #require(good["params"] as? [String: Any])
            var meta = try #require(params["_meta"] as? [String: Any]); meta[key] = nil
            params["_meta"] = meta; broken["params"] = params
            try expectRejected(broken, headers: headers(good, version: .july2026), status: 400, code: -32602)
        }
        var unknownHeaders = headers(good, version: .july2026)
        unknownHeaders["mcp-protocol-version"] = "2099-01-01"
        try expectRejected(good, headers: unknownHeaders, status: 400, code: -32020)
        let unknown = request("tools/list", params: ["_meta": ["io.modelcontextprotocol/protocolVersion": "2099-01-01",
                                                               "io.modelcontextprotocol/clientCapabilities": [:]]])
        try expectRejected(unknown, headers: unknownHeaders, status: 400, code: -32022)
        let legacy = request("tools/list")
        try expectRejected(legacy, headers: unknownHeaders, status: 400, code: -32022)
        if case let .rejected(failure) = try parse(unknown, headers: unknownHeaders) {
            let response = try decode(failure.body)
            let data = try #require((response["error"] as? [String: Any])?["data"] as? [String: Any])
            #expect(data["supported"] as? [String] == WritingMCPVersion.supported)
        }
        for method in ["unknown/method", "initialize"] {
            let response = try await send(request(method, version: .july2026), version: .july2026)
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
            #expect(try WritingMCPVersion.july2026.status(for: JSONSerialization.data(withJSONObject: response)) == 404)
        }
        let unknownTool = try await send(
            request("tools/call", params: ["name": "unknown"], version: .july2026),
            version: .july2026
        )
        #expect((unknownTool["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test(arguments: [WritingMCPVersion.november2025, .july2026])
    func httpSecurityAndFramingArePreserved(version: WritingMCPVersion) throws {
        let input = request("tools/list", version: version), good = headers(input, version: version)
        for (field, value, status) in [("authorization", nil, 401), ("authorization", "Bearer unregistered", 401),
                                       ("host", "evil.example", 403), ("origin", "https://evil.example", 403),
                                       ("transfer-encoding", "chunked", 403), ("content-length", "12000001", 400)] {
            var broken = good; broken[field] = value
            try expectRejected(input, headers: broken, status: status)
        }
        var allowedOrigin = good; allowedOrigin["origin"] = "http://127.0.0.1:\(port)"
        guard case .accepted = try parse(input, headers: allowedOrigin) else { Issue.record("Loopback origin rejected"); return }
        let wire = try message(input, headers: good)
        guard case .incomplete = WritingMCPHTTPRequest.parse(Data(wire.dropLast()), port: port, authorize: authorize) else {
            Issue.record("Partial body accepted"); return
        }
        guard case let .rejected(extra) = WritingMCPHTTPRequest
            .parse(wire + Data([0]), port: port, authorize: authorize) else {
            Issue.record("Extra message accepted"); return
        }
        #expect(extra.status == 400)
        guard case let .rejected(large) = WritingMCPHTTPRequest.parse(
            Data(repeating: 0, count: WritingMCPHTTPRequest.maximumMessageBytes + 1),
            port: port,
            authorize: authorize
        ) else {
            Issue.record("Oversized message accepted"); return
        }
        #expect(large.status == 413)
        guard case let .rejected(header) = WritingMCPHTTPRequest.parse(
            Data(repeating: 65, count: 16385),
            port: port,
            authorize: authorize
        ) else {
            Issue.record("Oversized header accepted"); return
        }
        #expect(header.status == 431)
    }

    @Test func modernUndoStillRequiresExplicitCurrentWorkAndSession() async throws {
        let document = NovelDocument.newDocument()
        var undid = 0
        let host = WritingAssistantHost(contextID: "current-session", capture: {
            WritingCapture(workId: document.id, document: document, episodeId: nil)
        }, records: { _ in [] }, append: { _ in }, synchronize: {}, apply: { _, _ in }, undo: { _ in undid += 1 })
        var args: [String: Any] = ["workId": document.id.uuidString, "sessionId": "stale", "requestId": UUID().uuidString]
        func undo() async throws -> [String: Any] {
            let reply = try await send(request("tools/call", params: ["name": "undo_edit", "arguments": args], version: .july2026),
                                       version: .july2026, host: host)
            return try #require(reply["result"] as? [String: Any])
        }
        #expect(try await undo()["isError"] as? Bool == true)
        args["sessionId"] = "current-session"
        args["workId"] = UUID().uuidString
        #expect(try await undo()["isError"] as? Bool == true)
        #expect(undid == 0)
        args["workId"] = document.id.uuidString
        let result = try await undo()
        #expect(result["isError"] as? Bool == false)
        #expect(result["resultType"] as? String == "complete")
        #expect(undid == 1)
    }

    @Test func malformedModernRequestsAreRejected() throws {
        let good = request("tools/list", version: .july2026), goodHeaders = headers(good, version: .july2026)
        for id in [NSNull(), true, 1.5] as [Any] {
            var broken = good; broken["id"] = id
            try expectRejected(broken, headers: goodHeaders, status: 400, code: -32600)
        }
        for (key, value) in [("io.modelcontextprotocol/clientCapabilities", "invalid" as Any),
                             ("io.modelcontextprotocol/protocolVersion", 2026 as Any),
                             ("io.modelcontextprotocol/clientInfo", ["name": "test"] as Any)] {
            var broken = good, params = try #require(good["params"] as? [String: Any])
            var meta = try #require(params["_meta"] as? [String: Any]); meta[key] = value
            params["_meta"] = meta; broken["params"] = params
            try expectRejected(broken, headers: goodHeaders, status: 400, code: -32602)
        }
        var malformedVersion = goodHeaders; malformedVersion["mcp-protocol-version"] = "2026-話"
        try expectRejected(good, headers: malformedVersion, status: 400, code: -32020)
        let name = "日本語のツール"
        let unicode = request("tools/call", params: ["name": name], version: .july2026)
        var encoded = headers(unicode, version: .july2026)
        encoded["mcp-name"] = "=?base64?" + Data(name.utf8).base64EncodedString() + "?="
        guard case .accepted = try parse(unicode, headers: encoded) else { Issue.record("UTF-8 encoded name rejected"); return }
    }

    @Test(arguments: [WritingMCPVersion.november2025, .july2026])
    func largerHTTPBodyIsExclusiveToSetThumbnail(version: WritingMCPVersion) throws {
        let image = String(repeating: "A", count: WritingMCPHTTPRequest.defaultBodyBytes + 1)
        let set = request("tools/call", params: ["name": "set_thumbnail", "arguments": ["image": image]], version: version)
        guard case .accepted = try parse(set, headers: headers(set, version: version)) else {
            Issue.record("Large set_thumbnail was rejected"); return
        }
        let edit = request("tools/call", params: ["name": "edit_work", "arguments": ["image": image]], version: version)
        var mirrored = headers(edit, version: version)
        mirrored["mcp-name"] = "set_thumbnail"
        try expectRejected(edit, headers: mirrored, status: 400)
        let list = request("tools/list", params: ["padding": image], version: version)
        try expectRejected(list, headers: headers(list, version: version), status: 400)
    }

    @Test func headerlessLegacyStillWorks() throws {
        let input = request("tools/list")
        var legacy = headers(input, version: .march2025)
        legacy["mcp-protocol-version"] = nil
        guard case let .accepted(_, _, version) = try parse(input, headers: legacy) else { Issue.record("Legacy rejected"); return }
        #expect(version == .march2025)
    }

    private func request(_ method: String, params: [String: Any] = [:],
                         version: WritingMCPVersion? = nil) -> [String: Any] {
        var params = params
        if let version, version == .july2026 {
            params["_meta"] = ["io.modelcontextprotocol/protocolVersion": version.rawValue,
                               "io.modelcontextprotocol/clientCapabilities": [:]]
        }
        var input: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !method.hasPrefix("notifications/") {
            input["id"] = 1
        }
        return input
    }

    private func headers(_ input: [String: Any], version: WritingMCPVersion) -> [String: String] {
        var headers = ["host": "127.0.0.1:\(port)", "authorization": "Bearer synthetic-test-token",
                       "content-type": "application/json", "accept": "application/json, text/event-stream", "mcp-protocol-version": version.rawValue]
        if version == .july2026 {
            headers["mcp-method"] = input["method"] as? String
            if input["method"] as? String == "tools/call" {
                headers["mcp-name"] = (input["params"] as? [String: Any])?["name"] as? String
            }
        }
        return headers
    }

    private func message(_ input: [String: Any], headers: [String: String]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: input)
        var headers = headers
        if headers["content-length"] == nil {
            headers["content-length"] = String(body.count)
        }
        return Data(("POST /mcp HTTP/1.1\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }
                .joined() + "\r\n").utf8) + body
    }

    private func authorize(_ token: String) -> UUID? {
        token == "synthetic-test-token" ? client : nil
    }

    private func parse(_ input: [String: Any], headers: [String: String]) throws -> WritingMCPHTTPRequest.Parsed {
        try WritingMCPHTTPRequest.parse(message(input, headers: headers), port: port, authorize: authorize)
    }

    private func expectRejected(
        _ input: [String: Any],
        headers: [String: String],
        status: Int,
        code: Int? = nil
    ) throws {
        guard case let .rejected(failure) = try parse(input, headers: headers) else { Issue.record("Invalid request accepted"); return }
        #expect(failure.status == status)
        if let code {
            let error = try #require(decode(failure.body)["error"] as? [String: Any])
            #expect(error["code"] as? Int == code)
        }
    }

    private func responseBody(
        _ input: [String: Any],
        version: WritingMCPVersion,
        host: WritingAssistantHost? = nil
    ) async throws -> Data? {
        guard case let .accepted(body, _, detected) = try parse(input, headers: headers(input, version: version)) else {
            Issue.record("Valid request rejected"); return nil
        }
        return await WritingMCPProtocol.respond(body, host: host, version: detected)
    }

    private func send(_ input: [String: Any], version: WritingMCPVersion,
                      host: WritingAssistantHost? = nil) async throws -> [String: Any] {
        let body = try #require(await responseBody(input, version: version, host: host))
        return try decode(body)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func toolOutput(_ response: [String: Any]) throws -> [String: Any] {
        let result = try #require(response["result"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: String]])?.first?["text"])
        return try decode(Data(text.utf8))
    }

    private func makeHost(_ document: NovelDocument, episode: EpisodeID?) -> WritingAssistantHost {
        WritingAssistantHost(contextID: "synthetic-session", capture: {
            WritingCapture(workId: document.id, document: document, episodeId: episode)
        }, records: { _ in [] }, append: { _ in }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
    }
}
