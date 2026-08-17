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

/// Canonical request builders shared by the transport and the operation
/// journal. Keeping one builder ensures an exact replay uses byte-identical
/// credentials and challenge fields.
public enum AuthCanonicalRequests {
    public static func exchangeApple(
        challenge: AuthChallenge,
        authorizationCode: Data,
        identityToken: Data,
        operationID: UUID
    ) throws -> AuthCanonicalCommand {
        guard let code = String(data: authorizationCode, encoding: .utf8),
              let token = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.invalidCredentialEncoding
        }
        return AuthJCS.object([
            ("authorizationCode", code), ("challengeId", challenge.challengeID.uuidString.lowercased()),
            ("identityToken", token), ("operationId", operationID.uuidString.lowercased()),
            ("provider", "apple"), ("state", challenge.state)
        ])
    }
}

// swiftlint:disable:next type_body_length
public struct FuminiwaHTTPAuthTransport: FuminiwaAuthTransport, Sendable {
    public let configuration: AuthClientConfiguration
    private let session: URLSession
    private let clock: @Sendable () -> Date
    private static let mediaType = "application/vnd.fuminiwa.auth.v1+jcs"
    private static let syncProtocolEpoch: UInt64 = 2
    private static let challengeErrorCodes: Set<String> = [
        "invalidIdentifier", "invalidRequest", "nonCanonicalJson", "unsafeInteger", "unknownField", "unsupportedMediaType",
        "operationIdReused", "payloadTooLarge", "clientVersionUnsupported", "rateLimited", "temporarilyUnavailable"
    ]
    private static let exchangeErrorCodes: Set<String> = [
        "invalidIdentifier", "invalidRequest", "nonCanonicalJson", "unsafeInteger", "unknownField", "unsupportedMediaType",
        "operationIdReused", "challengeConsumed", "challengeExpired", "challengeInvalid", "nonceMismatch",
        "providerAudienceMismatch", "providerCodeRejected", "providerIdentityInvalid", "providerIdentityMismatch",
        "providerIssuerMismatch", "stateMismatch", "providerExchangeIndeterminate", "payloadTooLarge",
        "clientVersionUnsupported", "rateLimited", "temporarilyUnavailable"
    ]
    private static let refreshErrorCodes: Set<String> = [
        "invalidIdentifier", "invalidRequest", "nonCanonicalJson", "unsafeInteger", "unknownField", "unsupportedMediaType",
        "rotationIdReused", "authenticationRequired", "refreshTokenExpired", "sessionRevoked", "refreshTokenReused",
        "payloadTooLarge", "clientVersionUnsupported", "rateLimited", "temporarilyUnavailable"
    ]
    private static let revokeErrorCodes: Set<String> = [
        "invalidIdentifier", "invalidRequest", "nonCanonicalJson", "unsafeInteger", "unknownField", "unsupportedMediaType",
        "operationIdReused", "authenticationRequired", "refreshTokenExpired", "sessionRevoked", "payloadTooLarge",
        "clientVersionUnsupported", "rateLimited", "temporarilyUnavailable"
    ]
    private static let capabilitiesErrorCodes: Set<String> = [
        "clientVersionUnsupported", "rateLimited", "temporarilyUnavailable"
    ]

    public init(configuration: AuthClientConfiguration, session: URLSession? = nil, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.configuration = configuration
        self.clock = clock
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
        try validate(response, data: data, status: 201, allowedErrorCodes: Self.challengeErrorCodes)
        let value = try validateCanonicalResponse(data)
        try validateClosedResponse(value, root: ["audience", "challengeId", "expiresAt", "flow", "nonce", "provider", "providerConfigurationId", "receipt", "requestedScopes", "state"], nested: [
            ("receipt", ["commandKind", "operationId", "replayUntil"])
        ])
        let challenge = try decode(AuthChallenge.self, data: data)
        try validateChallenge(challenge, raw: value, operationID: operationID)
        return challenge
    }

    public func fetchCapabilities() async throws -> AuthCapabilities {
        let request = makeRequest(path: "v1/auth/capabilities", method: "GET", body: Data())
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200, allowedErrorCodes: Self.capabilitiesErrorCodes)
        let value = try validateCanonicalResponse(data)
        try validateCapabilitiesClosed(value)
        let capabilities = try decode(AuthCapabilities.self, data: data)
        guard rawString(value, "serverInstanceId").map(Self.isLowercaseUUID) == true else { throw AuthError.invalidResponseSemantics }
        return capabilities
    }

    public func exchangeApple(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID) async throws -> FuminiwaSession {
        guard challenge.provider == .apple, challenge.flow == "native", challenge.requestedScopes.isEmpty else { throw AuthError.invalidProvider }
        let command = try AuthCanonicalRequests.exchangeApple(
            challenge: challenge,
            authorizationCode: authorizationCode,
            identityToken: identityToken,
            operationID: operationID
        )
        let path = "v1/auth/challenges/\(challenge.challengeID.uuidString.lowercased()):exchange"
        let request = makeRequest(path: path, method: "POST", body: command.bytes)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200, allowedErrorCodes: Self.exchangeErrorCodes)
        let value = try validateCanonicalResponse(data)
        try validateClosedResponse(value, root: ["binding", "receipt", "tokens"], nested: [
            ("binding", ["accountAuthEpoch", "accountFence", "accountId", "serverInstanceId", "sessionId", "syncProtocolEpoch"]),
            ("receipt", ["commandKind", "operationId", "replayUntil"]),
            ("tokens", ["accessToken", "accessTokenExpiresAt", "refreshGeneration", "refreshToken", "refreshTokenExpiresAt", "tokenType"])
        ])
        let session = try decode(AuthExchangeResult.self, data: data)
        try validateSessionResult(session, raw: value, operationID: operationID, current: nil)
        return FuminiwaSession(binding: session.binding, tokens: session.tokens, receipt: session.receipt)
    }

    public func refresh(session current: FuminiwaSession, rotationID: UUID) async throws -> FuminiwaSession {
        let command = AuthJCS.object([("rotationId", rotationID.uuidString.lowercased())])
        var request = makeRequest(path: "v1/auth/tokens:refresh", method: "POST", body: command.bytes)
        request.setValue("Bearer \(current.refreshToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200, allowedErrorCodes: Self.refreshErrorCodes)
        let value = try validateCanonicalResponse(data)
        try validateClosedResponse(value, root: ["binding", "receipt", "tokens"], nested: [
            ("binding", ["accountAuthEpoch", "accountFence", "accountId", "serverInstanceId", "sessionId", "syncProtocolEpoch"]),
            ("receipt", ["commandKind", "replayUntil", "rotationId"]),
            ("tokens", ["accessToken", "accessTokenExpiresAt", "refreshGeneration", "refreshToken", "refreshTokenExpiresAt", "tokenType"])
        ])
        let result = try decode(AuthRefreshResult.self, data: data)
        try validateSessionResult(result, raw: value, rotationID: rotationID, current: current)
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

    public func revoke(pending: AuthPendingRevoke) async throws {
        let command = AuthCanonicalCommand(bytes: pending.canonicalRequest)
        guard command.sha256 == pending.requestDigest,
              pending.requestFingerprint == "revoke:\(pending.session.sessionID.uuidString.lowercased())" else {
            throw AuthError.invalidWireResponse
        }
        let sealedCommand: AuthCanonicalJSONValue
        do {
            sealedCommand = try AuthCanonicalJSON.parse(pending.canonicalRequest)
        } catch {
            throw AuthError.invalidWireResponse
        }
        guard let members = sealedCommand.objectMembers,
              Set(members.map(\.0)) == Set(["operationId", "scope"]),
              rawString(sealedCommand, "operationId") == pending.operationID.uuidString.lowercased(),
              rawString(sealedCommand, "scope") == "currentSession" else {
            throw AuthError.invalidWireResponse
        }
        var request = makeRequest(path: "v1/auth/session:revoke", method: "POST", body: pending.canonicalRequest)
        request.setValue("Bearer \(pending.session.refreshToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, status: 200, allowedErrorCodes: Self.revokeErrorCodes)
        let value = try validateCanonicalResponse(data)
        try validateClosedResponse(value, root: ["accountAuthEpoch", "accountFence", "fenceChanged", "receipt", "revokedAt", "scope"], nested: [
            ("receipt", ["commandKind", "operationId", "replayUntil"])
        ])
        let result = try decode(AuthRevokeResult.self, data: data)
        try validateRevokeResult(result, raw: value, operationID: pending.operationID, current: pending.session)
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

    private func validate(_ response: URLResponse, data: Data, status: Int, allowedErrorCodes: Set<String>) throws {
        guard let http = response as? HTTPURLResponse else { throw AuthError.providerRejected }
        guard http.value(forHTTPHeaderField: "Cache-Control")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no-store" else { throw AuthError.missingNoStore }
        guard http.value(forHTTPHeaderField: "Pragma")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no-cache" else { throw AuthError.missingNoStore }
        guard http.value(forHTTPHeaderField: "Content-Type")?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.mediaType else { throw AuthError.invalidMediaType }
        guard !data.isEmpty else { throw AuthError.invalidWireResponse }
        guard http.statusCode != status else { return }
        throw try decodeRemoteError(data, allowedCodes: allowedErrorCodes)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func decodeRemoteError(_ data: Data, allowedCodes: Set<String>) throws -> AuthError {
        let value = try validateCanonicalResponse(data)
        guard let members = value.objectMembers else { throw AuthError.invalidWireResponse }
        let code = try requiredString(value, key: "code", maxUTF8: 128)
        guard allowedCodes.contains(code) else { throw AuthError.invalidWireResponse }

        let commonKeys = ["code", "recoveryAction", "requestId", "retryability"]
        let keys = Set(members.map(\.0))
        let expectedKeys: Set<String>
        switch code {
        case "operationIdReused": expectedKeys = Set(commonKeys + ["operationId"])
        case "rotationIdReused", "refreshTokenReused": expectedKeys = Set(commonKeys + ["rotationId"])
        case "challengeConsumed", "challengeExpired", "challengeInvalid",
             "nonceMismatch", "providerAudienceMismatch", "providerCodeRejected", "providerIdentityInvalid",
             "providerIdentityMismatch", "providerIssuerMismatch", "stateMismatch", "providerExchangeIndeterminate":
            expectedKeys = Set(commonKeys + ["challengeId", "operationId"])
        case "clientVersionUnsupported": expectedKeys = Set(commonKeys + ["minimumClientVersion"])
        case "payloadTooLarge": expectedKeys = Set(commonKeys + ["maxCanonicalCommandBytes"])
        case "rateLimited", "temporarilyUnavailable": expectedKeys = Set(commonKeys + ["retryAfterSeconds"])
        case "invalidIdentifier", "invalidRequest", "nonCanonicalJson", "unsafeInteger", "unknownField", "unsupportedMediaType",
             "accessTokenExpired", "authenticationRequired", "refreshTokenExpired", "sessionRevoked":
            expectedKeys = Set(commonKeys)
        default:
            throw AuthError.invalidWireResponse
        }
        guard keys == expectedKeys else { throw AuthError.invalidWireResponse }

        let requestID = try lowercaseUUID(value, key: "requestId")
        let recoveryAction = try enumValue(AuthRecoveryAction.self, value, key: "recoveryAction")
        let retryability = try enumValue(AuthRetryability.self, value, key: "retryability")
        let operationID = try optionalLowercaseUUID(value, key: "operationId")
        let challengeID = try optionalLowercaseUUID(value, key: "challengeId")
        let rotationID = try optionalLowercaseUUID(value, key: "rotationId")

        switch code {
        case "invalidIdentifier", "invalidRequest", "nonCanonicalJson", "unsafeInteger", "unknownField", "unsupportedMediaType", "payloadTooLarge":
            guard recoveryAction == .correctRequest, retryability == .never else { throw AuthError.invalidWireResponse }
        case "operationIdReused":
            guard recoveryAction == .none, retryability == .never, operationID != nil else { throw AuthError.invalidWireResponse }
        case "rotationIdReused":
            guard recoveryAction == .none, retryability == .never, rotationID != nil else { throw AuthError.invalidWireResponse }
        case "challengeConsumed", "challengeExpired", "challengeInvalid", "nonceMismatch", "providerAudienceMismatch",
             "providerCodeRejected", "providerIdentityInvalid", "providerIdentityMismatch", "providerIssuerMismatch", "stateMismatch",
             "providerExchangeIndeterminate":
            guard recoveryAction == .interactiveAppleSignIn,
                  retryability == .afterInteractiveAuthentication,
                  operationID != nil,
                  challengeID != nil else { throw AuthError.invalidWireResponse }
        case "accessTokenExpired":
            guard recoveryAction == .refreshFuminiwaSession, retryability == .afterTokenRefresh else { throw AuthError.invalidWireResponse }
        case "authenticationRequired", "refreshTokenExpired", "sessionRevoked":
            guard recoveryAction == .interactiveAppleSignIn, retryability == .afterInteractiveAuthentication else { throw AuthError.invalidWireResponse }
        case "refreshTokenReused":
            guard recoveryAction == .interactiveAppleSignIn, retryability == .afterInteractiveAuthentication, rotationID != nil else { throw AuthError.invalidWireResponse }
        case "clientVersionUnsupported":
            let minimumVersion = try requiredString(value, key: "minimumClientVersion", maxUTF8: 128)
            guard recoveryAction == .updateClient, retryability == .afterClientUpgrade,
                  Self.isSemanticVersion(minimumVersion) else { throw AuthError.invalidWireResponse }
            return .remote(AuthRemoteError(code: code, recoveryAction: recoveryAction, retryability: retryability, requestID: requestID, minimumClientVersion: minimumVersion))
        case "rateLimited", "temporarilyUnavailable":
            let retryAfter = try requiredUInt(value, key: "retryAfterSeconds")
            guard (1 ... 3600).contains(retryAfter),
                  recoveryAction == .retrySameRequestAfterBackoff,
                  retryability == .afterBackoff else { throw AuthError.invalidWireResponse }
            return .remote(AuthRemoteError(code: code, recoveryAction: recoveryAction, retryability: retryability, requestID: requestID, retryAfterSeconds: retryAfter))
        default:
            throw AuthError.invalidWireResponse
        }

        let maxBytes: UInt64?
        if code == "payloadTooLarge" {
            guard let value = value.objectValue(for: "maxCanonicalCommandBytes"),
                  case let .number(negative, magnitude) = value, !negative, magnitude == 65536 else { throw AuthError.invalidWireResponse }
            maxBytes = magnitude
        } else {
            maxBytes = nil
        }
        return .remote(AuthRemoteError(
            code: code,
            recoveryAction: recoveryAction,
            retryability: retryability,
            requestID: requestID,
            operationID: operationID,
            challengeID: challengeID,
            rotationID: rotationID,
            maxCanonicalCommandBytes: maxBytes
        ))
    }

    private func requiredString(_ value: AuthCanonicalJSONValue, key: String, maxUTF8: Int) throws -> String {
        guard let child = value.objectValue(for: key), case let .string(string) = child,
              !string.isEmpty, string.utf8.count <= maxUTF8 else { throw AuthError.invalidWireResponse }
        return string
    }

    private func requiredUInt(_ value: AuthCanonicalJSONValue, key: String) throws -> UInt64 {
        guard let child = value.objectValue(for: key), case let .number(negative, magnitude) = child, !negative else {
            throw AuthError.invalidWireResponse
        }
        return magnitude
    }

    private func lowercaseUUID(_ value: AuthCanonicalJSONValue, key: String) throws -> UUID {
        let string = try requiredString(value, key: key, maxUTF8: 36)
        guard Self.isLowercaseUUID(string), let uuid = UUID(uuidString: string) else { throw AuthError.invalidWireResponse }
        return uuid
    }

    private func optionalLowercaseUUID(_ value: AuthCanonicalJSONValue, key: String) throws -> UUID? {
        guard value.objectValue(for: key) != nil else { return nil }
        return try lowercaseUUID(value, key: key)
    }

    private func enumValue<T: RawRepresentable>(_: T.Type, _ value: AuthCanonicalJSONValue, key: String) throws -> T where T.RawValue == String {
        let raw = try requiredString(value, key: key, maxUTF8: 128)
        guard let result = T(rawValue: raw) else { throw AuthError.invalidWireResponse }
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.invalidWireResponse
        }
    }

    private func validateCanonicalResponse(_ data: Data) throws -> AuthCanonicalJSONValue {
        do { return try AuthCanonicalJSON.parse(data) } catch { throw AuthError.invalidCanonicalResponse }
    }

    private func validateClosedResponse(_ value: AuthCanonicalJSONValue, root: Set<String>, nested: [(String, Set<String>)]) throws {
        guard let members = value.objectMembers, Set(members.map(\.0)) == root else { throw AuthError.invalidWireResponse }
        for (name, keys) in nested {
            guard let child = value.objectValue(for: name), let childMembers = child.objectMembers,
                  Set(childMembers.map(\.0)) == keys else {
                throw AuthError.invalidWireResponse
            }
        }
    }

    private func validateCapabilitiesClosed(_ value: AuthCanonicalJSONValue) throws {
        try validateClosedResponse(value, root: [
            "authProtocolEpoch", "authProtocolNamespace", "authProtocolVersion", "canonicalization", "contentProtection", "limits",
            "minimumClientVersion", "providers", "serverInstanceId", "syncProtocolEpoch", "syncProtocolNamespace"
        ], nested: [
            ("contentProtection", ["e2ee", "profile", "serverCanReadContent", "userManagedContentKey"]),
            ("limits", [
                "accessTokenLifetimeSeconds", "authReceiptLifetimeSeconds", "challengeLifetimeSeconds", "maxCanonicalCommandBytes",
                "maxProviderClockSkewSeconds", "refreshTokenLifetimeSeconds"
            ])
        ])
        guard let providers = value.objectValue(for: "providers"), case let .array(providerValues) = providers, providerValues.count == 1,
              let provider = providerValues.first, let providerMembers = provider.objectMembers,
              Set(providerMembers.map(\.0)) == Set([
                  "authorizationEndpoint", "clientPlatforms", "flow", "issuer", "jwksEndpoint", "nativeAudiences", "provider",
                  "providerConfigurationId", "requestedScopes", "tokenEndpoint"
              ]) else { throw AuthError.invalidWireResponse }
        guard let audiences = provider.objectValue(for: "nativeAudiences"), case let .array(audienceValues) = audiences, audienceValues.count == 3 else {
            throw AuthError.invalidWireResponse
        }
        for audience in audienceValues {
            guard let members = audience.objectMembers, Set(members.map(\.0)) == Set(["audience", "clientPlatform"]) else {
                throw AuthError.invalidWireResponse
            }
        }
    }

    private func validateChallenge(_ challenge: AuthChallenge, raw: AuthCanonicalJSONValue, operationID: UUID) throws {
        let expectedAudience = configuration.clientPlatform == .macos
            ? "dev.serikayuzuki.fuminiwa"
            : "dev.serikayuzuki.fuminiwa.ios"
        guard challenge.provider == .apple,
              challenge.flow == "native",
              challenge.requestedScopes.isEmpty,
              challenge.providerConfigurationID == "apple-primary-fuminiwa-v1",
              challenge.audience == expectedAudience,
              challenge.state.count == 43,
              challenge.nonce.count == 43,
              challenge.state.allSatisfy(Self.isBase64URLCharacter),
              challenge.nonce.allSatisfy(Self.isBase64URLCharacter),
              challenge.expiresAt > clock().addingTimeInterval(-300),
              challenge.receipt.commandKind == "createChallenge",
              challenge.receipt.operationID == operationID,
              challenge.receipt.replayUntil > clock().addingTimeInterval(-300),
              rawString(raw, "challengeId").map(Self.isLowercaseUUID) == true,
              rawString(raw.objectValue(for: "receipt"), "operationId").map(Self.isLowercaseUUID) == true else {
            throw AuthError.invalidResponseSemantics
        }
    }

    private func validateSessionResult(_ result: some AuthSessionResult, raw: AuthCanonicalJSONValue, operationID: UUID? = nil, rotationID: UUID? = nil, current: FuminiwaSession?) throws {
        let binding = result.binding
        guard binding.syncProtocolEpoch == Self.syncProtocolEpoch,
              binding.accountAuthEpoch > 0,
              Self.isLowercaseUUID(binding.serverInstanceID.uuidString),
              Self.isLowercaseUUID(binding.sessionID.uuidString),
              Self.isOpaque(binding.accountID),
              Self.isOpaque(binding.accountFence),
              result.tokens.tokenType == "Bearer",
              Self.isAccessToken(result.tokens.accessToken),
              Self.isRefreshToken(result.tokens.refreshToken),
              result.tokens.refreshGeneration > 0,
              result.tokens.accessTokenExpiresAt <= result.tokens.refreshTokenExpiresAt,
              result.tokens.accessTokenExpiresAt > clock().addingTimeInterval(-300),
              result.tokens.refreshTokenExpiresAt > clock().addingTimeInterval(-300),
              result.receiptReplayUntil > clock().addingTimeInterval(-300) else {
            throw AuthError.invalidResponseSemantics
        }
        if let current {
            guard result.binding == current.binding,
                  result.tokens.refreshGeneration == current.refreshGeneration + 1 else { throw AuthError.invalidResponseSemantics }
        }
        if let operationID {
            guard result.receiptCommandKind == "exchangeAppleNativeCredential",
                  result.receiptOperationID == operationID,
                  rawString(raw.objectValue(for: "receipt"), "operationId").map(Self.isLowercaseUUID) == true else { throw AuthError.invalidResponseSemantics }
        }
        if let rotationID {
            guard result.receiptCommandKind == "rotateRefreshToken",
                  result.receiptRotationID == rotationID,
                  rawString(raw.objectValue(for: "receipt"), "rotationId").map(Self.isLowercaseUUID) == true else { throw AuthError.invalidResponseSemantics }
        }
        guard rawString(raw.objectValue(for: "binding"), "serverInstanceId").map(Self.isLowercaseUUID) == true,
              rawString(raw.objectValue(for: "binding"), "sessionId").map(Self.isLowercaseUUID) == true else { throw AuthError.invalidResponseSemantics }
    }

    private func validateRevokeResult(_ result: AuthRevokeResult, raw: AuthCanonicalJSONValue, operationID: UUID, current: FuminiwaSession) throws {
        guard result.scope == "currentSession",
              !result.fenceChanged,
              result.accountAuthEpoch == current.accountAuthEpoch,
              result.accountFence == current.accountFence,
              result.receipt.commandKind == "revokeCurrentSession",
              result.receipt.operationID == operationID,
              result.receipt.replayUntil > clock().addingTimeInterval(-300),
              Self.isOpaque(result.accountFence),
              rawString(raw.objectValue(for: "receipt"), "operationId").map(Self.isLowercaseUUID) == true else { throw AuthError.invalidResponseSemantics }
    }

    private func rawString(_ value: AuthCanonicalJSONValue?, _ key: String) -> String? {
        guard let value, case let .string(string) = value.objectValue(for: key) else { return nil }
        return string
    }

    private static func isLowercaseUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isBase64URLCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return isASCIIAlphaNumeric(scalar.value) || scalar.value == 0x5F || scalar.value == 0x2D
    }

    private static func isOpaque(_ value: String) -> Bool {
        (16 ... 1024).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { isASCIIAlphaNumeric($0.value) || $0.value == 0x5F || $0.value == 0x2D }
    }

    private static func isAccessToken(_ value: String) -> Bool {
        value.utf8.count >= 48 && value.utf8.count <= 256 && value.hasPrefix("fma1_") && isOpaque(String(value.dropFirst(5)))
    }

    private static func isRefreshToken(_ value: String) -> Bool {
        value.utf8.count >= 48 && value.utf8.count <= 256 && value.hasPrefix("fmr1_") && isOpaque(String(value.dropFirst(5)))
    }

    private static func isASCIIAlphaNumeric(_ value: UInt32) -> Bool {
        (0x30 ... 0x39).contains(value) || (0x41 ... 0x5A).contains(value) || (0x61 ... 0x7A).contains(value)
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil
    }
}

private protocol AuthSessionResult {
    var binding: AuthSessionBinding { get }
    var tokens: AuthSessionTokens { get }
    var receiptCommandKind: String { get }
    var receiptOperationID: UUID? { get }
    var receiptRotationID: UUID? { get }
    var receiptReplayUntil: Date { get }
}

private struct AuthExchangeResult: Decodable, AuthSessionResult {
    let binding: AuthSessionBinding
    let receipt: AuthReceipt
    let tokens: AuthSessionTokens

    var receiptCommandKind: String {
        receipt.commandKind
    }

    var receiptOperationID: UUID? {
        receipt.operationID
    }

    var receiptRotationID: UUID? {
        nil
    }

    var receiptReplayUntil: Date {
        receipt.replayUntil
    }
}

private struct AuthRefreshResult: Decodable, AuthSessionResult {
    let binding: AuthSessionBinding
    let receipt: RefreshRotationReceipt
    let tokens: AuthSessionTokens

    var receiptCommandKind: String {
        receipt.commandKind
    }

    var receiptOperationID: UUID? {
        nil
    }

    var receiptRotationID: UUID? {
        receipt.rotationID
    }

    var receiptReplayUntil: Date {
        receipt.replayUntil
    }
}

private struct AuthRevokeResult: Decodable {
    let accountAuthEpoch: UInt64
    let accountFence: String
    let fenceChanged: Bool
    let receipt: AuthReceipt
    let revokedAt: Date
    let scope: String
}
