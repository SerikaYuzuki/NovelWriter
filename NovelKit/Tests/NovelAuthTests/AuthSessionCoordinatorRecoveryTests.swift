import Foundation
import NovelAuth
import Testing

@Suite("Auth exchange recovery")
struct AuthSessionCoordinatorRecoveryTests {
    @Test("terminal interactive Apple failures clear the exchange journal")
    func terminalInteractiveFailureClearsJournal() async throws {
        let challenge = fixtureChallenge()
        let transport = InteractiveFailureTransport(code: "providerIdentityInvalid")
        let vault = InMemoryAuthSessionVault()
        let coordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: fixtureLimits(),
            platform: .ios
        )

        await expectRestart {
            _ = try await coordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: Data("code-1".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: fixtureUUID("58000000-0000-4000-8000-000000000001")
            )
        }
        let terminalRecord = await vault.snapshot()
        #expect(terminalRecord.operations.isEmpty)

        await transport.allowSuccess()
        _ = try await coordinator.completeAppleSignIn(
            challenge: challenge,
            authorizationCode: Data("fresh-code".utf8),
            identityToken: Data("header.payload.signature".utf8),
            operationID: fixtureUUID("58000000-0000-4000-8000-000000000002")
        )
        let recoveredRecord = await vault.snapshot()
        #expect(recoveredRecord.operations.isEmpty)
    }

    @Test("indeterminate Apple exchange retains the exact replay lane")
    func indeterminateFailureRetainsJournal() async throws {
        let challenge = fixtureChallenge()
        let operationID = fixtureUUID("58100000-0000-4000-8000-000000000001")
        let transport = InteractiveFailureTransport(code: "providerExchangeIndeterminate")
        let vault = InMemoryAuthSessionVault()
        let coordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: fixtureLimits(),
            platform: .ios
        )

        await expectRestart {
            _ = try await coordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: Data("code-1".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: operationID
            )
        }
        let interrupted = await vault.snapshot()
        #expect(interrupted.operations.count == 1)
        #expect(interrupted.operations[0].operationID == operationID)

        await transport.allowSuccess()
        _ = try await coordinator.completeAppleSignIn(
            challenge: challenge,
            authorizationCode: Data("code-1".utf8),
            identityToken: Data("header.payload.signature".utf8),
            operationID: operationID
        )
        let replayedRecord = await vault.snapshot()
        #expect(replayedRecord.operations.isEmpty)
    }

    @Test("auth diagnostics contain only a closed error code")
    func diagnosticTokenRedactsRemoteMetadata() {
        let requestID = fixtureUUID("90000000-0000-4000-8000-000000000051")
        let error = AuthError.remote(AuthRemoteError(
            code: "providerIdentityInvalid",
            recoveryAction: .interactiveAppleSignIn,
            retryability: .afterInteractiveAuthentication,
            requestID: requestID,
            operationID: fixtureUUID("90000000-0000-4000-8000-000000000052"),
            challengeID: fixtureUUID("90000000-0000-4000-8000-000000000053")
        ))
        #expect(error.diagnosticToken == "AuthError.remote(providerIdentityInvalid)")
        #expect(!error.diagnosticToken.contains(requestID.uuidString))
    }

    private func expectRestart(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("interactive failure unexpectedly succeeded")
        } catch let error as AuthError {
            #expect(error == .restartAuthentication)
        } catch {
            Issue.record("unexpected auth error: \(error)")
        }
    }
}

private actor InteractiveFailureTransport: FuminiwaAuthTransport {
    private let failureCode: String
    private var shouldFail = true

    init(code: String) {
        failureCode = code
    }

    func allowSuccess() {
        shouldFail = false
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(
        challenge _: AuthChallenge,
        authorizationCode _: Data,
        identityToken _: Data,
        operationID _: UUID
    ) async throws -> FuminiwaSession {
        if shouldFail {
            throw AuthError.remote(AuthRemoteError(
                code: failureCode,
                recoveryAction: .interactiveAppleSignIn,
                retryability: .afterInteractiveAuthentication,
                requestID: fixtureUUID("90000000-0000-4000-8000-000000000041")
            ))
        }
        return fixtureSession()
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }
}

private func fixtureUUID(_ value: String) -> UUID {
    UUID(uuidString: value) ?? UUID()
}

private func fixtureChallenge() -> AuthChallenge {
    AuthChallenge(
        challengeID: fixtureUUID("20000000-0000-4000-8000-000000000001"),
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        audience: "dev.serikayuzuki.fuminiwa.ios",
        providerConfigurationID: "apple-primary-fuminiwa-v1",
        state: String(repeating: "A", count: 43),
        nonce: String(repeating: "B", count: 43),
        receipt: AuthReceipt(
            commandKind: "createChallenge",
            operationID: fixtureUUID("10000000-0000-4000-8000-000000000001"),
            replayUntil: Date(timeIntervalSince1970: 1_778_000_000)
        )
    )
}

private func fixtureLimits() throws -> AuthLimits {
    try AuthLimits(
        accessTokenLifetimeSeconds: 900,
        authReceiptLifetimeSeconds: 7_776_000,
        challengeLifetimeSeconds: 300,
        maxCanonicalCommandBytes: 65536,
        maxProviderClockSkewSeconds: 300,
        refreshTokenLifetimeSeconds: 7_776_000
    )
}

private func fixtureSession() -> FuminiwaSession {
    let binding = AuthSessionBinding(
        serverInstanceID: fixtureUUID("00000000-0000-4000-8000-000000000001"),
        syncProtocolEpoch: 2,
        accountID: "acct_AAAAAAAAAAAAAAAA",
        accountAuthEpoch: 1,
        accountFence: "fence_AAAAAAAAAAAAAAAAAAAA",
        sessionID: fixtureUUID("40000000-0000-4000-8000-000000000001")
    )
    return FuminiwaSession(
        binding: binding,
        tokens: AuthSessionTokens(
            accessToken: "fma1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_755_312_900),
            refreshToken: "fmr1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_778_000_000),
            refreshGeneration: 1
        ),
        receipt: AuthReceipt(
            commandKind: "exchangeAppleNativeCredential",
            operationID: fixtureUUID("30000000-0000-4000-8000-000000000001"),
            replayUntil: Date(timeIntervalSince1970: 1_778_000_000)
        )
    )
}
