#if os(macOS)
import CoreFoundation
import Foundation

/// All revision-specific behavior lives here; application work/session grants are separate.
enum WritingMCPVersion: String, CaseIterable {
    case march2025 = "2025-03-26"
    case june2025 = "2025-06-18"
    case november2025 = "2025-11-25"
    case july2026 = "2026-07-28"

    static var supported: [String] {
        allCases.map(\.rawValue)
    }

    static let metadataPrefix = "io.modelcontextprotocol/"
    static let serverInfo = ["name": "FUMINIWA", "version": "1.0"]
    static let instructions = "登録した接続を信頼しています。ユーザーが指定した範囲だけをscope.pathsに変換してください。"
        + "編集前にread_workで現在のworkId、sessionId、対象値を確認してください。権限は各依頼だけ有効です。"
    private var modern: Bool {
        self == .july2026
    }

    func supports(_ method: String) -> Bool {
        switch method {
        case "initialize": !modern
        case "server/discover": modern
        case "ping", "tools/list", "tools/call": true
        default: false
        }
    }

    static func initializeResult(_ requested: String) -> [String: Any] {
        let version = Self(rawValue: requested).flatMap { $0.modern ? nil : $0 } ?? .november2025
        return ["protocolVersion": version.rawValue, "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": serverInfo, "instructions": instructions]
    }

    func complete(_ result: [String: Any], method: String) -> [String: Any] {
        guard modern else { return result }
        var result = result
        result["resultType"] = "complete"
        result["_meta"] = [Self.metadataPrefix + "serverInfo": Self.serverInfo]
        if method == "tools/list" || method == "server/discover" {
            result["ttlMs"] = 0
            result["cacheScope"] = "private"
        }
        return result
    }

    func status(for body: Data?) -> Int {
        guard let body else { return 202 }
        guard modern, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any], let code = error["code"] as? Int else { return 200 }
        return code == -32601 ? 404 : 400
    }

    func validateMetadata(_ request: [String: Any]) -> WritingMCPFailure? {
        guard modern else { return nil }
        let params = request["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        guard meta?[Self.metadataPrefix + "protocolVersion"] as? String == rawValue,
              meta?[Self.metadataPrefix + "clientCapabilities"] is [String: Any] else {
            return .rpc(
                request,
                code: -32602,
                message: "Invalid params: required per-request metadata missing or invalid"
            )
        }
        if let info = meta?[Self.metadataPrefix + "clientInfo"] {
            guard let info = info as? [String: Any], info["name"] is String, info["version"] is String else {
                return .rpc(request, code: -32602, message: "Invalid params: clientInfo")
            }
        }
        return nil
    }

    static func resolveHTTP(_ body: Data, headers: [String: String]) -> Result<Self, WritingMCPFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return .failure(.rpc([:], code: -32700, message: "Parse error"))
        }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
              request["method"] is String else {
            return .failure(.rpc([:], code: -32600, message: "Invalid request"))
        }
        let meta = (request["params"] as? [String: Any])?["_meta"] as? [String: Any]
        let bodyVersion = meta?[metadataPrefix + "protocolVersion"] as? String
        let headerVersion = headers["mcp-protocol-version"]
        if let headerVersion, !validHeader(headerVersion) {
            return .failure(.rpc(request, code: -32020, message: "Header mismatch: malformed MCP-Protocol-Version"))
        }
        // A body declaring a version must agree with its header before version negotiation.
        // In particular, modern metadata must not fall back to the headerless legacy default.
        if let bodyVersion, bodyVersion != headerVersion {
            return .failure(.rpc(request, code: -32020, message: "Header mismatch: MCP-Protocol-Version"))
        }
        let requested = headerVersion ?? march2025.rawValue
        guard let version = Self(rawValue: requested) else {
            return .failure(.rpc(request, code: -32022, message: "Unsupported protocol version",
                                 data: ["supported": supported, "requested": requested]))
        }
        guard version.modern else { return .success(version) }
        if let failure = version.validateRequest(request, headers: headers) {
            return .failure(failure)
        }
        return .success(version)
    }

    private func validateRequest(_ request: [String: Any], headers: [String: String]) -> WritingMCPFailure? {
        let method = request["method"] as? String ?? ""
        guard Self.validHeader(headers["mcp-method"]), headers["mcp-method"] == method else {
            return .rpc(request, code: -32020, message: "Header mismatch: Mcp-Method")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let nameField = method == "resources/read" ? "uri" : "name"
        if ["tools/call", "resources/read", "prompts/get"].contains(method) || headers["mcp-name"] != nil {
            guard let header = headers["mcp-name"], Self.validHeader(header),
                  let name = Self.decodeHeader(header), name == params[nameField] as? String else {
                return .rpc(request, code: -32020, message: "Header mismatch: Mcp-Name")
            }
        }
        if let failure = validateMetadata(request) {
            return failure
        }
        if let id = request["id"] {
            guard Self.validID(id) else {
                return .rpc([:], code: -32600, message: "Invalid request ID")
            }
        }
        return nil
    }

    private static func validID(_ id: Any) -> Bool {
        if id is String {
            return true
        }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    }

    private static func validHeader(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.utf8.allSatisfy { $0 == 9 || (32 ... 126).contains($0) }
    }

    private static func decodeHeader(_ value: String) -> String? {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?=") else { return value }
        guard let data = Data(base64Encoded: String(value.dropFirst(9).dropLast(2))) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct WritingMCPFailure: Error {
    let status: Int
    let body: Data

    static func rpc(_ request: [String: Any], code: Int, message: String, data: [String: Any]? = nil) -> Self {
        var error: [String: Any] = ["code": code, "message": message]
        error["data"] = data
        var response: [String: Any] = ["jsonrpc": "2.0", "error": error]
        response["id"] = request["id"]
        return Self(status: code == -32601 ? 404 : 400,
                    body: (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data())
    }
}
#endif
