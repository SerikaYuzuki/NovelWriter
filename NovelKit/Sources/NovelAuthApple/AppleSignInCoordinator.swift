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

    override public init() {
        super.init()
    }

    public func authorize(using challenge: AuthChallenge) async throws -> AppleAuthorizationPayload {
        guard challenge.provider == .apple, challenge.expiresAt > Date() else {
            throw AuthError.challengeExpired
        }
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
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
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let authorizationCode = credential.authorizationCode else {
            continuation?.resume(throwing: AuthError.providerRejected)
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
