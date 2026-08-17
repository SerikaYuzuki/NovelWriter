import Foundation
import NovelAuth

#if canImport(AuthenticationServices)
import AuthenticationServices
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Thin native adapter. It only obtains Apple's one-use credentials; the
/// backend performs nonce/state/JWS/code validation and issues FUMINIWA tokens.
@MainActor
public final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleAuthorizationPayload, Error>?
    private var expectedChallenge: AuthChallenge?

    override public init() {
        super.init()
    }

    public func authorize(using challenge: AuthChallenge) async throws -> AppleAuthorizationPayload {
        guard continuation == nil else { throw AuthError.authorizationInProgress }
        guard challenge.provider == .apple, challenge.flow == "native", challenge.requestedScopes.isEmpty,
              challenge.expiresAt > Date(), !challenge.state.isEmpty, !challenge.nonce.isEmpty else {
            throw AuthError.challengeExpired
        }
        expectedChallenge = challenge
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = []
        request.state = challenge.state
        request.nonce = challenge.nonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    public func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
        #endif
    }

    public func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let challenge = expectedChallenge
        expectedChallenge = nil
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let authorizationCode = credential.authorizationCode,
              let challenge else {
            continuation?.resume(throwing: AuthError.providerRejected)
            continuation = nil
            return
        }
        do {
            try AppleAuthorizationCallbackValidator.validate(
                challenge: challenge,
                credentialState: credential.state,
                now: Date()
            )
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        continuation?.resume(
            returning: AppleAuthorizationPayload(
                userHandle: credential.user,
                authorizationCode: authorizationCode,
                identityToken: identityToken
            )
        )
        continuation = nil
    }

    public func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        expectedChallenge = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#else
public final class AppleSignInCoordinator: Sendable {
    public init() {}
}
#endif

public struct AppleAuthorizationPayload: Sendable {
    /// Opaque handle needed by `getCredentialState`; never put it in SQLite,
    /// `.novelpkg`, logs, or the sync protocol.
    public let userHandle: String
    public let authorizationCode: Data
    public let identityToken: Data

    public init(userHandle: String, authorizationCode: Data, identityToken: Data) {
        self.userHandle = userHandle
        self.authorizationCode = authorizationCode
        self.identityToken = identityToken
    }
}

/// Pure callback seam used by the native delegate and tests. The server-side
/// identity-token verifier remains authoritative for nonce validation; the
/// client only binds the native callback to its exact server challenge state.
public enum AppleAuthorizationCallbackValidator {
    public static func validate(challenge: AuthChallenge, credentialState: String?, now: Date) throws {
        guard challenge.provider == .apple,
              challenge.flow == "native",
              challenge.requestedScopes.isEmpty,
              challenge.expiresAt > now,
              credentialState == challenge.state else {
            if credentialState != challenge.state {
                throw AuthError.stateMismatch
            }
            throw AuthError.challengeExpired
        }
    }
}

/// Separate provider-only boundary for Apple's credential-state API.  The
/// handle is never part of FUMINIWA session/binding state or a sync request.
public protocol AppleCredentialStateHandleVault: Sendable {
    func load(providerConfigurationID: String) async throws -> String?
    func save(_ userHandle: String, providerConfigurationID: String) async throws
    func remove(providerConfigurationID: String) async throws
}

public actor InMemoryAppleCredentialStateHandleVault: AppleCredentialStateHandleVault {
    private var values: [String: String] = [:]
    public init() {}
    public func load(providerConfigurationID: String) async throws -> String? {
        values[providerConfigurationID]
    }

    public func save(_ userHandle: String, providerConfigurationID: String) async throws {
        values[providerConfigurationID] = userHandle
    }

    public func remove(providerConfigurationID: String) async throws {
        values[providerConfigurationID] = nil
    }
}

#if canImport(Security)
import Security

/// Production Apple user-handle storage.  This item is intentionally a
/// separate Keychain service and is never part of the FUMINIWA token record.
public actor KeychainAppleCredentialStateHandleVault: AppleCredentialStateHandleVault {
    private let service: String

    public init(service: String = "jp.fuminiwa.apple-credential-state") {
        self.service = service
    }

    public func load(providerConfigurationID: String) async throws -> String? {
        var query = baseQuery(providerConfigurationID: providerConfigurationID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AppleCredentialStateVaultError.status(status)
        }
        return value
    }

    public func save(_ userHandle: String, providerConfigurationID: String) async throws {
        guard !userHandle.isEmpty, let data = userHandle.data(using: .utf8) else {
            throw AppleCredentialStateVaultError.invalidHandle
        }
        let query = baseQuery(providerConfigurationID: providerConfigurationID)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else { throw AppleCredentialStateVaultError.status(updateStatus) }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AppleCredentialStateVaultError.status(addStatus) }
    }

    public func remove(providerConfigurationID: String) async throws {
        let status = SecItemDelete(baseQuery(providerConfigurationID: providerConfigurationID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppleCredentialStateVaultError.status(status) }
    }

    private func baseQuery(providerConfigurationID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerConfigurationID
        ]
    }
}

public enum AppleCredentialStateVaultError: Error, Equatable, Sendable {
    case status(OSStatus)
    case invalidHandle
}
#endif
