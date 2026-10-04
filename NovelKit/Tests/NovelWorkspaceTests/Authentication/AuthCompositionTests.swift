import AuthenticationServices
import Foundation
import NovelAuth
import NovelAuthApple
import NovelWorkspace
import Testing

@Suite("Auth composition compatibility")
struct AuthCompositionTests {
    @Test(arguments: [AuthClientPlatform.macos, .ios])
    @MainActor
    func platformValuesAndProviderMode(_ platform: AuthClientPlatform) throws {
        let service = platform == .macos
            ? "dev.serikayuzuki.fuminiwa.sync"
            : "dev.serikayuzuki.fuminiwa.sync.ios"
        // Construction does not load/save these production items or send HTTP.
        let composition = AuthComposition(
            origin: URL(string: "https://auth.invalid"), keychainService: service,
            clientPlatform: platform, appleFlow: platform == .macos ? .browser : .native
        )
        #expect(composition.keychainService == service)
        #expect(composition.clientPlatform == platform)
        #expect(composition.sessionCoordinator != nil)
        #expect((composition.appleAuthenticationOrchestrator != nil) == (platform == .ios))
        #expect(try AuthComposition.limits() == AuthLimits(
            accessTokenLifetimeSeconds: 900, authReceiptLifetimeSeconds: 86400,
            challengeLifetimeSeconds: 300, maxCanonicalCommandBytes: 65536,
            maxProviderClockSkewSeconds: 300, refreshTokenLifetimeSeconds: 86400
        ))
    }

    @Test
    @MainActor
    func absentOriginKeepsVaultAndDisablesNetworkAuth() {
        let composition = AuthComposition(
            origin: nil, keychainService: "P10.unused.\(UUID().uuidString)",
            clientPlatform: .ios, appleFlow: .native
        )
        #expect(composition.sessionVault is KeychainAuthSessionVault)
        #expect(composition.sessionCoordinator == nil)
        #expect(composition.appleAuthenticationOrchestrator == nil)
    }

    @Test
    @MainActor
    func nativeAndBrowserUseInjectedPresentationAnchor() throws {
        let anchor = ASPresentationAnchor()
        let apple = AppleSignInCoordinator(presentationAnchorProvider: { anchor })
        let native = ASAuthorizationController(authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()])
        #expect(apple.presentationAnchor(for: native) === anchor)
        let browser = BrowserSignInCoordinator(presentationAnchorProvider: { anchor })
        let session = try ASWebAuthenticationSession(url: #require(URL(string: "https://auth.invalid")), callbackURLScheme: "fixture") { _, _ in }
        #expect(browser.presentationAnchor(for: session) === anchor)
    }
}
