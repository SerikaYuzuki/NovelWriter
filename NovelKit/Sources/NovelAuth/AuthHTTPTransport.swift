import Foundation

/// Small URLSession adapter for the versioned auth wire. It never stores an
/// Apple credential and only returns the opaque FUMINIWA session pair.
public struct FuminiwaHTTPAuthTransport: FuminiwaAuthTransport, Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func createAppleChallenge() async throws -> AuthChallenge {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/challenges"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(AuthChallenge.self, from: data)
    }

    public func exchangeApple(
        challenge: AuthChallenge,
        authorizationCode: Data,
        identityToken: Data,
        operationID: UUID
    ) async throws -> FuminiwaSession {
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("v1/auth/challenges")
                .appendingPathComponent("\(challenge.challengeID.uuidString.lowercased()):exchange")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try encoder.encode(AppleExchangeBody(
            operationID: operationID,
            provider: "apple",
            state: challenge.state,
            authorizationCode: Self.utf8OrBase64(authorizationCode),
            identityToken: Self.utf8OrBase64(identityToken)
        ))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(FuminiwaSession.self, from: data)
    }

    public func refresh(session: FuminiwaSession, rotationID: UUID) async throws -> FuminiwaSession {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/tokens:refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(session.refreshToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(RefreshBody(rotationID: rotationID))
        let (data, response) = try await sessionData(for: request)
        try validate(response, data: data)
        return try decoder.decode(FuminiwaSession.self, from: data)
    }

    public func revoke(session: FuminiwaSession) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/session:revoke"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await sessionData(for: request)
        try validate(response, data: data)
    }

    private func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") ?? true else {
            throw AuthError.providerRejected
        }
        _ = data
    }

    private static func utf8OrBase64(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct AppleExchangeBody: Encodable {
    let operationID: UUID
    let provider: String
    let state: String
    let authorizationCode: String
    let identityToken: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case provider
        case state
        case authorizationCode
        case identityToken
    }
}

private struct RefreshBody: Encodable {
    let rotationID: UUID

    enum CodingKeys: String, CodingKey {
        case rotationID = "rotationId"
    }
}
