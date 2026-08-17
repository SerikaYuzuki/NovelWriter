import CryptoKit
import Foundation

public struct AuthCanonicalCommand: Sendable, Equatable {
    public let bytes: Data
    public let sha256: Data
    public init(bytes: Data) {
        self.bytes = bytes; sha256 = Data(SHA256.hash(data: bytes))
    }
}

/// RFC 8785 JCS for the closed auth command objects.  All v1 command values
/// are strings, so this small encoder avoids Foundation's noncanonical key and
/// escaping behavior while keeping the exact UTF-8 bytes auditable in tests.
public enum AuthJCS {
    public static func object(_ values: [(String, String)]) -> AuthCanonicalCommand {
        let body = values.sorted { $0.0 < $1.0 }.map { "\"\(escape($0.0))\":\"\(escape($0.1))\"" }.joined(separator: ",")
        return AuthCanonicalCommand(bytes: Data("{\(body)}".utf8))
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0 ..< 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

public struct FuminiwaHTTPAuthTransport: FuminiwaAuthTransport, Sendable {
    public let configuration: AuthClientConfiguration
    private let session: URLSession
    private static let mediaType = "application/vnd.fuminiwa.auth.v1+jcs"

    public init(configuration: AuthClientConfiguration, session: URLSession? = nil) throws {
        self.configuration = configuration
        if let session {
            guard session.configuration.urlCache == nil,
                  session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData else { throw AuthError.invalidWireResponse }
            self.session = session
        } else {
            let urlConfiguration = URLSessionConfiguration.ephemeral
            urlConfiguration.urlCache = nil
            urlConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: urlConfiguration)
        }
    }

    public func createAppleChallenge(clientPlatform: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge {
        guard clientPlatform == configuration.clientPlatform else { throw AuthError.invalidProvider }
        let command = AuthJCS.object([
            ("clientPlatform", clientPlatform.rawValue), ("flow", "native"),
            ("operationId", operationID.uuidString.lowercased()), ("provider", "apple")
        ])
        let request = makeRequest(path: "v1/auth/challenges", method: "POST", body: command.bytes)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 201)
        try validateClosedResponse(data, root: ["audience", "challengeId", "expiresAt", "flow", "nonce", "provider", "providerConfigurationId", "receipt", "requestedScopes", "state"], nested: [
            ("receipt", ["commandKind", "operationId", "replayUntil"])
        ])
        let challenge = try decode(AuthChallenge.self, data: data)
        guard challenge.provider == .apple, challenge.flow == "native", challenge.requestedScopes.isEmpty,
              challenge.receipt.commandKind == "createChallenge", challenge.receipt.operationID == operationID,
              challenge.providerConfigurationID == "apple-primary-fuminiwa-v1" else { throw AuthError.invalidWireResponse }
        return challenge
    }

    public func exchangeApple(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID) async throws -> FuminiwaSession {
        guard challenge.provider == .apple, challenge.flow == "native", challenge.requestedScopes.isEmpty else { throw AuthError.invalidProvider }
        guard let code = String(data: authorizationCode, encoding: .utf8), let token = String(data: identityToken, encoding: .utf8) else { throw AuthError.invalidCredentialEncoding }
        let command = AuthJCS.object([
            ("authorizationCode", code), ("challengeId", challenge.challengeID.uuidString.lowercased()),
            ("identityToken", token), ("operationId", operationID.uuidString.lowercased()),
            ("provider", "apple"), ("state", challenge.state)
        ])
        let path = "v1/auth/challenges/\(challenge.challengeID.uuidString.lowercased()):exchange"
        let request = makeRequest(path: path, method: "POST", body: command.bytes)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200)
        try validateClosedResponse(data, root: ["binding", "receipt", "tokens"], nested: [
            ("binding", ["accountAuthEpoch", "accountFence", "accountId", "serverInstanceId", "sessionId", "syncProtocolEpoch"]),
            ("receipt", ["commandKind", "operationId", "replayUntil"]),
            ("tokens", ["accessToken", "accessTokenExpiresAt", "refreshGeneration", "refreshToken", "refreshTokenExpiresAt", "tokenType"])
        ])
        let session = try decode(AuthExchangeResult.self, data: data)
        guard session.receipt.commandKind == "exchangeAppleNativeCredential", session.receipt.operationID == operationID,
              session.binding.syncProtocolEpoch == 1 else { throw AuthError.invalidWireResponse }
        return FuminiwaSession(binding: session.binding, tokens: session.tokens, receipt: session.receipt)
    }

    public func refresh(session current: FuminiwaSession, rotationID: UUID) async throws -> FuminiwaSession {
        let command = AuthJCS.object([("rotationId", rotationID.uuidString.lowercased())])
        var request = makeRequest(path: "v1/auth/tokens:refresh", method: "POST", body: command.bytes)
        request.setValue("Bearer \(current.refreshToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200)
        try validateClosedResponse(data, root: ["binding", "receipt", "tokens"], nested: [
            ("binding", ["accountAuthEpoch", "accountFence", "accountId", "serverInstanceId", "sessionId", "syncProtocolEpoch"]),
            ("receipt", ["commandKind", "replayUntil", "rotationId"]),
            ("tokens", ["accessToken", "accessTokenExpiresAt", "refreshGeneration", "refreshToken", "refreshTokenExpiresAt", "tokenType"])
        ])
        let result = try decode(AuthRefreshResult.self, data: data)
        guard result.receipt.commandKind == "rotateRefreshToken", result.receipt.rotationID == rotationID,
              result.tokens.refreshGeneration == current.refreshGeneration + 1,
              result.binding == current.binding else { throw AuthError.invalidWireResponse }
        let receipt = AuthReceipt(
            commandKind: result.receipt.commandKind,
            operationID: rotationID,
            replayUntil: result.receipt.replayUntil
        )
        return FuminiwaSession(
            binding: result.binding,
            tokens: result.tokens,
            receipt: receipt,
            rotationReceipt: result.receipt
        )
    }

    public func revoke(session current: FuminiwaSession, operationID: UUID) async throws {
        let command = AuthJCS.object([("operationId", operationID.uuidString.lowercased()), ("scope", "currentSession")])
        var request = makeRequest(path: "v1/auth/session:revoke", method: "POST", body: command.bytes)
        request.setValue("Bearer \(current.refreshToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200)
        try validateClosedResponse(data, root: ["accountAuthEpoch", "accountFence", "fenceChanged", "receipt", "revokedAt", "scope"], nested: [
            ("receipt", ["commandKind", "operationId", "replayUntil"])
        ])
        let result = try decode(AuthRevokeResult.self, data: data)
        guard result.scope == "currentSession", !result.fenceChanged, result.accountAuthEpoch == current.accountAuthEpoch,
              result.accountFence == current.accountFence, result.receipt.commandKind == "revokeCurrentSession",
              result.receipt.operationID == operationID else { throw AuthError.invalidWireResponse }
    }

    private func makeRequest(path: String, method: String, body: Data) -> URLRequest {
        var request = URLRequest(url: configuration.origin.appendingPathComponent(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.mediaType, forHTTPHeaderField: "Accept")
        request.setValue(configuration.clientVersion, forHTTPHeaderField: "X-Fuminiwa-Client-Version")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = body
        return request
    }

    private func validate(_ response: URLResponse, data: Data, status: Int) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == status else { throw AuthError.providerRejected }
        guard http.value(forHTTPHeaderField: "Cache-Control")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no-store" else { throw AuthError.missingNoStore }
        guard http.value(forHTTPHeaderField: "Pragma")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no-cache" else { throw AuthError.missingNoStore }
        guard http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first.map(String.init) == Self.mediaType else { throw AuthError.invalidMediaType }
        guard !data.isEmpty else { throw AuthError.invalidWireResponse }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) } catch { throw AuthError.invalidWireResponse }
    }

    private func validateClosedResponse(_ data: Data, root: Set<String>, nested: [(String, Set<String>)]) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == root else {
            throw AuthError.invalidWireResponse
        }
        for (name, keys) in nested {
            guard let child = object[name] as? [String: Any], Set(child.keys) == keys else {
                throw AuthError.invalidWireResponse
            }
        }
    }
}

private struct AuthExchangeResult: Decodable {
    let binding: AuthSessionBinding
    let receipt: AuthReceipt
    let tokens: AuthSessionTokens
}

private struct AuthRefreshResult: Decodable {
    let binding: AuthSessionBinding
    let receipt: RefreshRotationReceipt
    let tokens: AuthSessionTokens
}

private struct AuthRevokeResult: Decodable {
    let accountAuthEpoch: UInt64
    let accountFence: String
    let fenceChanged: Bool
    let receipt: AuthReceipt
    let revokedAt: Date
    let scope: String
}
