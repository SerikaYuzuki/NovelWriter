import Foundation
import NovelAuth
import NovelWorkspace
import Testing

@MainActor
enum AccountTransitionConformance {
    /// All implementations run this driver, including the reference fake.
    static func run(_ scenario: AuthCharacterizationScenario, host: any AccountTransitionHost) async throws {
        let fixture = host.fixture
        await host.seedDirtyUIAndRequests()
        let initialScope = host.scope
        switch scenario {
        case .launchRestore:
            await host.restore()
            #expect(host.session == fixture.first)
        case .apple, .google, .switchAccount:
            let provider: AuthProvider = scenario == .google ? .google : .apple
            await host.signIn(provider)
            #expect(host.session == fixture.second)
            #expect(await fixture.transport.providers == [provider])
        case .signOut:
            await host.signOut()
            await host.settleRevoke()
            #expect(host.session == nil)
            #expect(host.uiState == .signedOut)
            #expect(try await fixture.vault.load() == nil)
            #expect(await fixture.transport.revokeCount == 1)
        case .refresh:
            try await refresh(host: host, initialScope: initialScope)
            return
        case .exchangeFailure, .unsignedFailure, .committedExchangeFailure:
            await fixture.transport.configure(outcome: .failure, holdExchange: true)
            try await failedExchange(host: host, cancellation: false, committed: scenario == .committedExchangeFailure)
            let expected = scenario == .unsignedFailure ? nil : scenario == .committedExchangeFailure ? fixture.second : fixture.first
            #expect(host.session == expected)
            #expect((host.failureNotice != nil) == (expected != nil))
            if expected == nil {
                #expect(isFailed(host.uiState))
            }
        case .exchangeCancellation, .unsignedCancellation:
            await fixture.transport.configure(outcome: .cancellation, holdExchange: true)
            try await failedExchange(host: host, cancellation: true, committed: false)
            #expect(host.session == (scenario == .unsignedCancellation ? nil : fixture.first))
            if scenario == .unsignedCancellation {
                #expect(host.uiState == .signedOut)
            }
        case .rejectedIME:
            fixture.rejectIME = true
            await host.signIn(.apple)
            #expect(host.session == fixture.first)
            #expect(host.uiState == .signedIn(accountID: fixture.first.accountID))
            #expect(await fixture.transport.providers.isEmpty)
        case .oldEpochTransition:
            let succeeded = await host.transition(authCharacterizationSession(account: "account-b", epoch: 1))
            #expect(!succeeded)
            #expect(host.session == nil)
            assertUnsupportedUI(host)
        case .oldEpochRestore:
            await host.restore()
            await host.settleRevoke()
            await host.retryRevoke()
            #expect(host.session == nil)
            assertUnsupportedUI(host)
            #expect(try await fixture.vault.load() == nil)
        case .revokedCredentialRestore:
            try await fixture.handles.save("fixture-handle", providerConfigurationID: "apple-primary-fuminiwa-v1")
            await fixture.credentialProvider.setRevoked()
            await host.restore()
            #expect(host.session == nil)
        case .pendingRevoke:
            try await pendingRevoke(host: host)
        case .queuedSignOut:
            try await queuedSignOut(host: host)
        case .revokeSuspension:
            try await revokeSuspension(host: host)
        }
        try await assertSharedBoundary(scenario, host: host)
    }

    private static func assertSharedBoundary(_ scenario: AuthCharacterizationScenario, host: any AccountTransitionHost) async throws {
        let fixture = host.fixture
        #expect(!fixture.preparationLeases.isEmpty)
        #expect(fixture.preparationLeases.allSatisfy { $0 > 0 })
        #expect(fixture.preparationAccounts.first == .some(fixture.initialSession?.accountID))
        switch scenario {
        case .apple, .google, .switchAccount, .exchangeFailure,
             .committedExchangeFailure, .exchangeCancellation:
            #expect(fixture.preparationLeases.count == 3)
        case .unsignedFailure, .unsignedCancellation:
            #expect(fixture.preparationLeases.count == 2)
        default: break
        }
        #expect(host.leaseCount == 0)
        #expect(host.localOperationsAllowed)
        #expect(await host.requestsCancelled())
        if scenario != .rejectedIME {
            #expect(!host.hasScopedUI)
            #expect(try await host.persistedTitle() == fixture.dirtyTitle)
        }
        if host.session == nil, scenario != .rejectedIME {
            #expect(try await host.isWorkParked())
        }
    }

    private static func revokeSuspension(host: any AccountTransitionHost) async throws {
        let fixture = host.fixture
        await fixture.transport.configure(holdRevoke: true)
        var returned = false
        let signingOut = Task { await host.signOut(); returned = true }
        do {
            try await waitForAuthCharacterization { await fixture.transport.revokeWaiting }
            try await waitForAuthCharacterization { returned }
            #expect(host.session == nil)
            #expect(host.leaseCount == 0)
            #expect(host.localOperationsAllowed)
            #expect(try await host.isWorkParked())
            #expect(try await host.persistedTitle() == fixture.dirtyTitle)
        } catch {
            await fixture.transport.releaseRevoke()
            await signingOut.value
            await host.settleRevoke()
            throw error
        }
        await fixture.transport.releaseRevoke()
        await signingOut.value
        await host.settleRevoke()
    }

    private static func pendingRevoke(host: any AccountTransitionHost) async throws {
        let fixture = host.fixture
        await fixture.transport.configure(failRevoke: true)
        await host.signOut()
        await host.settleRevoke()
        #expect(try await fixture.vault.loadPendingRevoke() != nil)
        #expect(isFailed(host.uiState))
        // Retry must revoke A's journal without touching a newly saved B.
        try await fixture.vault.save(fixture.second)
        await fixture.transport.configure()
        await host.retryRevoke()
        #expect(try await fixture.vault.load() == fixture.second)
        #expect(try await fixture.vault.loadPendingRevoke() == nil)
        #expect(await fixture.transport.revokeCount == 2)
    }

    private static func queuedSignOut(host: any AccountTransitionHost) async throws {
        let fixture = host.fixture
        await fixture.transport.configure(holdExchange: true)
        let signingIn = Task { await host.signIn(.apple) }
        try await waitForAuthCharacterization { await fixture.transport.exchangeWaiting }
        var signOutReturned = false
        let signingOut = Task { await host.signOut(); signOutReturned = true }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(!signOutReturned)
        #expect(host.localOperationsAllowed)
        await fixture.transport.releaseExchange()
        await signingIn.value
        await signingOut.value
        await host.settleRevoke()
        #expect(host.session == nil)
    }

    private static func refresh(host: any AccountTransitionHost, initialScope: WorkspaceAccountScope) async throws {
        let fixture = host.fixture
        #expect(await host.refresh())
        let refreshed = try #require(host.session)
        #expect(refreshed.binding == fixture.first.binding)
        #expect(refreshed.tokens != fixture.first.tokens)
        #expect(host.session == refreshed)
        #expect(host.scope.accountID == initialScope.accountID)
        #expect(host.scope.accountFence == initialScope.accountFence)
        #expect(host.scope.serverInstanceID == initialScope.serverInstanceID)
        #expect(host.scope.protocolEpoch == initialScope.protocolEpoch)
        #expect(host.scope.generation == initialScope.generation)
        #expect(host.hasScopedUI)
        #expect(await !host.requestsCancelled())
        #expect(fixture.preparationLeases.isEmpty)
        #expect(host.leaseCount == 0)
    }

    private static func failedExchange(host: any AccountTransitionHost, cancellation: Bool, committed: Bool) async throws {
        let signingIn = Task { await host.signIn(.apple) }
        do {
            try await waitForAuthCharacterization { await host.fixture.transport.exchangeWaiting }
            // These observations happen before exchange returns or commits its vault.
            #expect(host.session == nil)
            #expect(host.uiState == .signingIn)
            #expect(host.leaseCount > 0)
            #expect(try await host.isWorkParked())
            #expect(try await host.persistedTitle() == host.fixture.dirtyTitle)
            #expect(!host.hasScopedUI)
            #expect(host.localOperationsAllowed)
            #expect(await host.requestsCancelled())
            if committed {
                try await host.fixture.vault.save(host.fixture.second)
            }
            if cancellation {
                signingIn.cancel()
            }
        } catch {
            await host.fixture.transport.releaseExchange()
            await signingIn.value
            throw error
        }
        await host.fixture.transport.releaseExchange()
        await signingIn.value
    }

    private static func assertUnsupportedUI(_ host: any AccountTransitionHost) {
        #expect(isFailed(host.uiState))
    }

    private static func isFailed(_ state: WorkspaceAuthUIState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }
}
