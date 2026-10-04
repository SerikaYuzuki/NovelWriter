@testable import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelWorkspace
import Testing

enum AuthCharacterizationScenario: String, CaseIterable, Sendable {
    case launchRestore, apple, google, signOut, switchAccount, refresh
    case exchangeFailure, exchangeCancellation, unsignedFailure, unsignedCancellation
    case committedExchangeFailure, rejectedIME, oldEpochTransition, oldEpochRestore
    case revokedCredentialRestore, pendingRevoke, queuedSignOut, revokeSuspension
}

/// This is a characterization port, not the future P10c transition service.
/// The very same driver is compiled into the package and both app test bundles.
@MainActor
protocol AccountTransitionHost: AnyObject {
    var profile: AuthCharacterizationProfile { get }
    var fixture: AccountTransitionFixture { get }
    var session: FuminiwaSession? { get }
    var uiState: WorkspaceAuthUIState { get }
    var scope: WorkspaceAccountScope { get }
    var leaseCount: Int { get }
    var hasScopedUI: Bool { get }
    var failureNotice: String? { get }
    var localOperationsAllowed: Bool { get }
    func seedDirtyUIAndRequests() async
    func restore() async
    func signIn(_ provider: AuthProvider) async
    func signOut() async
    func settleRevoke() async
    func retryRevoke() async
    func transition(_ session: FuminiwaSession?) async -> Bool
    func persistedTitle() async throws -> String?
    func isWorkParked() async throws -> Bool
    func requestsCancelled() async -> Bool
}

enum AuthCharacterizationProfile {
    case reference, macOS, iOS
    var refreshInvalidates: Bool {
        self == .macOS
    }

    var oldEpochTransitionSucceeds: Bool {
        self == .macOS
    }

    var removesOldEpochVault: Bool {
        self == .macOS
    }

    var consultsCredentialState: Bool {
        self == .macOS
    }

    var queuesSignOut: Bool {
        self == .macOS
    }

    var cancellationWithoutSession: WorkspaceAuthUIState {
        self == .macOS ? .signedOut : .failed("Appleでのサインインがキャンセルされました")
    }
}

@MainActor
final class AccountTransitionFixture {
    let scenario: AuthCharacterizationScenario
    let first = authCharacterizationSession(account: "test-account")
    let second = authCharacterizationSession(account: "account-b")
    let vault: InMemoryAuthSessionVault
    let transport: CharacterizationAuthTransport
    let coordinator: AuthSessionCoordinator
    let handles = InMemoryAppleCredentialStateHandleVault()
    let credentialProvider = CharacterizationCredentialProvider()
    let editor = EditorCommandSession()
    var preparationLeases: [Int] = []
    var preparationAccounts: [String?] = []
    var rejectIME = false
    let dirtyTitle = "P10 auth dirty checkpoint"

    init(scenario: AuthCharacterizationScenario, platform: AuthClientPlatform) throws {
        self.scenario = scenario
        let initial: FuminiwaSession? = switch scenario {
        case .apple, .google, .unsignedFailure, .unsignedCancellation: nil
        case .oldEpochRestore: authCharacterizationSession(account: "test-account", epoch: 1)
        default: first
        }
        vault = InMemoryAuthSessionVault(session: initial)
        transport = CharacterizationAuthTransport(destination: second)
        coordinator = try AuthSessionCoordinator(
            transport: transport, vault: vault, authLimits: AuthComposition.limits(), platform: platform
        )
    }

    var initialSession: FuminiwaSession? {
        switch scenario {
        case .launchRestore, .oldEpochRestore, .revokedCredentialRestore,
             .apple, .google, .unsignedFailure, .unsignedCancellation: nil
        default: first
        }
    }

    func prepare(leaseCount: Int, session: FuminiwaSession?) -> Bool {
        preparationLeases.append(leaseCount)
        preparationAccounts.append(session?.accountID)
        return !rejectIME
    }

    func orchestrator() -> AppleAuthenticationOrchestrator {
        AppleAuthenticationOrchestrator(
            authSessionCoordinator: coordinator,
            authorizationProvider: CharacterizationAppleProvider(),
            credentialStateHandleVault: handles,
            credentialStateProvider: credentialProvider
        )
    }
}

func authCharacterizationSession(account: String, epoch: UInt64 = 2) -> FuminiwaSession {
    let now = Date()
    return FuminiwaSession(
        binding: AuthSessionBinding(
            serverInstanceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            syncProtocolEpoch: epoch, accountID: account, accountAuthEpoch: 1,
            accountFence: account == "test-account" ? "test-fence" : "fence-b", sessionID: UUID()
        ),
        tokens: AuthSessionTokens(
            accessToken: "fixture-access", accessTokenExpiresAt: now.addingTimeInterval(900),
            refreshToken: "fixture-refresh", refreshTokenExpiresAt: now.addingTimeInterval(86400), refreshGeneration: 1
        ),
        receipt: AuthReceipt(commandKind: "exchangeApple", operationID: UUID(), replayUntil: now.addingTimeInterval(300))
    )
}

actor CharacterizationAuthTransport: FuminiwaAuthTransport, BrowserAuthTransport {
    enum Outcome { case success, failure, cancellation }
    let destination: FuminiwaSession
    var outcome = Outcome.success
    var holdExchange = false
    var holdRevoke = false
    var failRevoke = false
    private(set) var exchangeWaiting = false
    private(set) var revokeWaiting = false
    private(set) var providers: [AuthProvider] = []
    private(set) var platforms: [AuthClientPlatform] = []
    private(set) var revokeCount = 0
    private var exchangeContinuation: CheckedContinuation<Void, Never>?
    private var revokeContinuation: CheckedContinuation<Void, Never>?

    init(destination: FuminiwaSession) {
        self.destination = destination
    }

    func configure(outcome: Outcome = .success, holdExchange: Bool = false, holdRevoke: Bool = false, failRevoke: Bool = false) {
        self.outcome = outcome; self.holdExchange = holdExchange
        self.holdRevoke = holdRevoke; self.failRevoke = failRevoke
    }

    func releaseExchange() {
        exchangeContinuation?.resume(); exchangeContinuation = nil
    }

    func releaseRevoke() {
        revokeContinuation?.resume(); revokeContinuation = nil
    }

    func createAppleChallenge(clientPlatform: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge {
        platforms.append(clientPlatform)
        return AuthChallenge(
            challengeID: UUID(), expiresAt: Date().addingTimeInterval(300),
            audience: clientPlatform == .macos ? "dev.serikayuzuki.fuminiwa" : "dev.serikayuzuki.fuminiwa.ios",
            providerConfigurationID: "apple-primary-fuminiwa-v1", state: String(repeating: "A", count: 43),
            nonce: String(repeating: "B", count: 43),
            receipt: AuthReceipt(commandKind: "createChallenge", operationID: operationID, replayUntil: Date().addingTimeInterval(300))
        )
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        providers.append(.apple)
        return try await exchange()
    }

    private func exchange() async throws -> FuminiwaSession {
        if holdExchange {
            exchangeWaiting = true
            await withCheckedContinuation { exchangeContinuation = $0 }
            exchangeWaiting = false
        }
        switch outcome {
        case .success: return destination
        case .failure: throw AuthError.providerRejected
        case .cancellation: throw CancellationError()
        }
    }

    func startBrowserAuthentication(provider: AuthProvider, claimHash _: String) async throws -> BrowserAuthAttempt {
        providers.append(provider)
        // Decode the real public wire value; no extra production initializer needed.
        return try JSONDecoder().decode(BrowserAuthAttempt.self, from: Data(
            "{\"attemptId\":\"11111111-1111-1111-1111-111111111111\",\"authorizationURL\":\"https://auth.invalid/authorize\",\"expiresIn\":300}".utf8
        ))
    }

    func claimBrowserAuthentication(attemptID _: UUID, secret _: String) async throws -> FuminiwaSession? {
        try await exchange()
    }

    func refresh(session: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        FuminiwaSession(
            binding: session.binding,
            tokens: AuthSessionTokens(accessToken: "fixture-rotated", accessTokenExpiresAt: Date().addingTimeInterval(900),
                                      refreshToken: "fixture-rotated-refresh", refreshTokenExpiresAt: Date().addingTimeInterval(86400),
                                      refreshGeneration: session.tokens.refreshGeneration + 1),
            receipt: session.receipt
        )
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        revokeCount += 1
        if holdRevoke {
            revokeWaiting = true
            await withCheckedContinuation { revokeContinuation = $0 }
            revokeWaiting = false
        }
        if failRevoke {
            throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
final class CharacterizationAppleProvider: AppleAuthorizationProviding {
    func authorize(using _: AuthChallenge) async throws -> AppleAuthorizationPayload {
        AppleAuthorizationPayload(userHandle: "fixture-handle", authorizationCode: Data("fixture-code".utf8), identityToken: Data("fixture-token".utf8))
    }
}

actor CharacterizationCredentialProvider: AppleCredentialStateProviding {
    var revoked = false
    func setRevoked() {
        revoked = true
    }

    func credentialState(for _: String) async throws -> AppleCredentialState {
        revoked ? .revoked : .authorized
    }
}

@MainActor
func waitForAuthCharacterization(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !predicate() {
        guard ContinuousClock.now < deadline else {
            throw AuthCharacterizationTimeout()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct AuthCharacterizationTimeout: Error {}

func authCharacterizationConflict() -> SyncV2ConflictProjection {
    SyncV2ConflictProjection(
        conflictID: UUID(), revision: 1, baseSnapshotID: nil,
        localSnapshotID: SnapshotID(data: Data("fixture-local".utf8)),
        remoteSnapshotID: SnapshotID(data: Data("fixture-remote".utf8)), sourceGeneration: 1
    )
}
