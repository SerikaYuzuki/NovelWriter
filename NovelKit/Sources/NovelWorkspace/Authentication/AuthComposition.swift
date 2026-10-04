import AuthenticationServices
import Foundation
import NovelAuth
import NovelAuthApple

/// Construction only. Account-transition ownership remains in each app (D-111 P10b).
@MainActor
public struct AuthComposition {
    public enum AppleFlow { case browser, native }

    public let sessionVault: any AuthSessionVault
    public let sessionCoordinator: AuthSessionCoordinator?
    public let appleSignInCoordinator: AppleSignInCoordinator
    public let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    public let keychainService: String
    public let clientPlatform: AuthClientPlatform
    public let browserAuthorization: @MainActor @Sendable (URL) async throws -> Void

    public init(
        origin: URL?,
        keychainService: String,
        clientPlatform: AuthClientPlatform,
        appleFlow: AppleFlow,
        presentationAnchorProvider: (@MainActor () -> ASPresentationAnchor)? = nil,
        phaseObserver: (@MainActor (AppleAuthenticationPhase) -> Void)? = nil
    ) {
        self.keychainService = keychainService
        self.clientPlatform = clientPlatform
        browserAuthorization = { url in
            try await Self.authorizeBrowser(url: url, presentationAnchorProvider: presentationAnchorProvider)
        }
        let vault = KeychainAuthSessionVault(service: keychainService)
        sessionVault = vault
        let coordinator: AuthSessionCoordinator? = if let origin,
                                                      let configuration = try? AuthClientConfiguration(
                                                          origin: origin, clientVersion: "0.1.0", clientPlatform: clientPlatform
                                                      ),
                                                      let transport = try? FuminiwaHTTPAuthTransport(configuration: configuration),
                                                      let limits = try? Self.limits() {
            AuthSessionCoordinator(transport: transport, vault: vault, authLimits: limits, platform: clientPlatform)
        } else {
            nil
        }
        sessionCoordinator = coordinator
        let apple = presentationAnchorProvider.map {
            AppleSignInCoordinator(presentationAnchorProvider: $0)
        } ?? AppleSignInCoordinator()
        appleSignInCoordinator = apple
        appleAuthenticationOrchestrator = if appleFlow == .native, let coordinator {
            AppleAuthenticationOrchestrator(
                authSessionCoordinator: coordinator,
                authorizationProvider: apple,
                credentialStateHandleVault: KeychainAppleCredentialStateHandleVault(),
                credentialStateProvider: SystemAppleCredentialStateProvider(),
                phaseObserver: phaseObserver
            )
        } else {
            nil
        }
    }

    public static func limits() throws -> AuthLimits {
        try AuthLimits(
            accessTokenLifetimeSeconds: 900,
            authReceiptLifetimeSeconds: 86400,
            challengeLifetimeSeconds: 300,
            maxCanonicalCommandBytes: 65536,
            maxProviderClockSkewSeconds: 300,
            refreshTokenLifetimeSeconds: 86400
        )
    }

    /// A fresh browser coordinator for each authorization, matching both existing apps.
    public static func authorizeBrowser(
        url: URL,
        presentationAnchorProvider: (@MainActor () -> ASPresentationAnchor)? = nil
    ) async throws {
        let browser = presentationAnchorProvider.map {
            BrowserSignInCoordinator(presentationAnchorProvider: $0)
        } ?? BrowserSignInCoordinator()
        try await browser.authorize(url: url)
    }
}
