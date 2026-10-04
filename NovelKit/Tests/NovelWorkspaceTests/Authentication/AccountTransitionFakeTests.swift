import Foundation
import NovelAuth
import NovelWorkspace
import Testing

@Suite("Shared account transition conformance")
struct AccountTransitionFakeTests {
    @Test(arguments: AuthCharacterizationScenario.allCases)
    @MainActor
    func conformance(_ scenario: AuthCharacterizationScenario) async throws {
        try await AccountTransitionConformance.run(scenario, host: FakeAccountTransitionHost(scenario: scenario))
    }
}

@MainActor
private final class FakeAccountTransitionHost: AccountTransitionHost {
    let profile = AuthCharacterizationProfile.reference
    let fixture: AccountTransitionFixture
    var session: FuminiwaSession?
    var uiState: WorkspaceAuthUIState
    var scope: WorkspaceAccountScope {
        WorkspaceAccountScope(accountID: session?.accountID, accountFence: session?.accountFence,
                              serverInstanceID: session?.serverInstanceID.uuidString.lowercased(),
                              protocolEpoch: session.map { Int64($0.syncProtocolEpoch) }, generation: generation)
    }

    var leaseCount = 0
    var hasScopedUI = false
    var failureNotice: String? {
        nil
    }

    var localOperationsAllowed: Bool {
        true
    }

    private var generation: UInt64 = 0
    private var title: String?
    private var cancelled = false
    private var parked = false
    private var request = false

    init(scenario: AuthCharacterizationScenario) throws {
        fixture = try AccountTransitionFixture(scenario: scenario, platform: .ios)
        session = fixture.initialSession
        uiState = session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
    }

    func seedDirtyUIAndRequests() async {
        hasScopedUI = true
    }

    func persistedTitle() async throws -> String? {
        title
    }

    func isWorkParked() async throws -> Bool {
        parked
    }

    func requestsCancelled() async -> Bool {
        cancelled
    }

    private func acquire() {
        leaseCount += 1; cancelled = true; generation &+= 1
    }

    private func release() {
        leaseCount -= 1
    }

    private func apply(_ session: FuminiwaSession?) -> Bool {
        guard fixture.prepare(leaseCount: leaseCount, session: self.session) else { return false }
        title = fixture.dirtyTitle
        parked = session == nil || session?.syncProtocolEpoch != 2 || session?.accountID != fixture.first.accountID
        hasScopedUI = false
        self.session = session?.syncProtocolEpoch == 2 ? session : nil
        uiState = session.map { $0.syncProtocolEpoch == 2 ? .signedIn(accountID: $0.accountID) : .failed("unsupported") } ?? .signedOut
        return session == nil || session?.syncProtocolEpoch == 2
    }

    func transition(_ session: FuminiwaSession?) async -> Bool {
        if session?.binding == self.session?.binding {
            self.session = session; return true
        }
        acquire(); defer { release() }
        return apply(session)
    }

    func restore() async {
        acquire(); defer { release() }
        _ = await apply(try? fixture.vault.load())
    }

    func signIn(_ provider: AuthProvider) async {
        guard !request else { return }
        request = true; acquire()
        defer { release(); request = false }
        let previous = session
        guard apply(nil) else { return }
        uiState = .signingIn
        do {
            let next = if provider == .apple {
                try await fixture.orchestrator().signIn()
            } else {
                try await fixture.coordinator.signInBrowser(provider: provider) { _ in }
            }
            _ = apply(next)
        } catch {
            let recovered = await (try? fixture.vault.load()) ?? previous
            if let recovered {
                _ = apply(recovered)
            } else if error is CancellationError {
                uiState = profile.cancellationWithoutSession
            } else {
                uiState = .failed("exchange failed")
            }
        }
    }

    func signOut() async {
        guard !request else { return }
        acquire(); _ = apply(nil); release()
        do { try await fixture.coordinator.signOut() }
        catch { uiState = .failed("revoke pending") }
    }

    func settleRevoke() async {}
    func retryRevoke() async {
        try? await fixture.coordinator.resumePendingRevoke()
    }
}
