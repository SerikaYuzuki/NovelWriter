import Foundation
import NovelAuth
import NovelSyncV2Application
import NovelWorkspace
import Testing

@Suite("Shared account transition conformance")
struct AccountTransitionFakeTests {
    @Test(arguments: AuthCharacterizationScenario.allCases)
    @MainActor
    func conformance(_ scenario: AuthCharacterizationScenario) async throws {
        try await AccountTransitionConformance.run(scenario, host: FakeAccountTransitionHost(scenario: scenario))
    }

    @Test("stale request cleanup cannot release a newer owner")
    @MainActor
    func staleRequestRelease() async throws {
        let host = try FakeAccountTransitionHost(scenario: .signOut)
        let old = try #require(await host.core.beginRequest())
        await host.core.releaseRequest(owner: old, resume: true)
        let current = try #require(await host.core.beginRequest())
        await host.core.releaseRequest(owner: old, resume: true)
        #expect(host.core.requestOwner == current)
        #expect(host.core.requested)
        await host.core.releaseRequest(owner: current, resume: true)
    }

    @Test("failed old-epoch parking retains the vault session")
    @MainActor
    func rejectedOldEpochRestore() async throws {
        let host = try FakeAccountTransitionHost(scenario: .oldEpochRestore)
        host.fixture.rejectIME = true
        await host.restore()
        #expect(try await host.fixture.vault.load()?.syncProtocolEpoch == 1)
        #expect(host.session == nil)
        #expect(!host.core.requested)
    }

    @Test("detached A revoke cannot publish over B's exchange or clear B")
    @MainActor
    func revokeDuringNewExchange() async throws {
        let host = try FakeAccountTransitionHost(scenario: .signOut)
        await host.fixture.transport.configure(holdExchange: true, holdRevoke: true)
        await host.signOut()
        try await waitForAuthCharacterization { await host.fixture.transport.revokeWaiting }
        #expect(!host.core.requested)
        let signingIn = Task { await host.signIn(.apple) }
        do {
            try await waitForAuthCharacterization { await host.fixture.transport.exchangeWaiting }
            await host.fixture.transport.releaseRevoke()
            await host.settleRevoke()
            #expect(host.uiState == .signingIn)
        } catch {
            await host.fixture.transport.releaseRevoke()
            await host.fixture.transport.releaseExchange()
            await signingIn.value
            throw error
        }
        await host.fixture.transport.releaseExchange()
        await signingIn.value
        #expect(host.session == host.fixture.second)
        #expect(try await host.fixture.vault.load() == host.fixture.second)
        #expect(!host.core.requested)
    }
}

@MainActor
private final class FakeAccountTransitionHost: AccountTransitionHost, AccountTransitionPort {
    let fixture: AccountTransitionFixture
    var authSession: FuminiwaSession?
    var authUIState: WorkspaceAuthUIState
    var session: FuminiwaSession? {
        authSession
    }

    var uiState: WorkspaceAuthUIState {
        authUIState
    }

    var authSessionCoordinator: AuthSessionCoordinator? {
        fixture.coordinator
    }

    var snapshotSyncV2Application: SyncV2Application? {
        nil
    }

    lazy var core = AccountTransitionCoordinator(host: self)
    var scope: WorkspaceAccountScope {
        WorkspaceAccountScope(accountID: session?.accountID, accountFence: session?.accountFence,
                              serverInstanceID: session?.serverInstanceID.uuidString.lowercased(),
                              protocolEpoch: session.map { Int64($0.syncProtocolEpoch) }, generation: generation)
    }

    var leaseCount: Int {
        core.requested ? 1 : 0
    }

    var hasScopedUI = false
    var failureNotice: String?
    var localOperationsAllowed: Bool {
        !core.inProgress
    }

    private var generation: UInt64 = 0
    private var title: String?
    private var cancelled = false
    private var parked = false

    init(scenario: AuthCharacterizationScenario) throws {
        fixture = try AccountTransitionFixture(scenario: scenario, platform: .ios)
        authSession = fixture.initialSession
        authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
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

    func transition(_ session: FuminiwaSession?) async -> Bool {
        await core.transition(to: session, state: session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut)
    }

    func refresh() async -> Bool {
        await core.refresh()
    }

    func restore() async {
        await core.restore()
    }

    func signIn(_ provider: AuthProvider) async {
        await core.signIn(provider)
    }

    func signOut() async {
        await core.signOut()
    }

    func settleRevoke() async {
        await core.revokeTask?.value
    }

    func retryRevoke() async {
        core.retryPendingRevoke(); await settleRevoke()
    }

    func canExchangeAccountSession(_: AuthProvider) -> Bool {
        true
    }

    func accountBinding(_ session: FuminiwaSession) -> SyncV2AccountScopeBinding {
        SyncV2AccountScopeBinding(accountID: session.accountID, accountFence: session.accountFence,
                                  serverInstanceID: session.serverInstanceID.uuidString.lowercased(), protocolEpoch: Int64(session.syncProtocolEpoch))
    }

    func invalidateAccountOperations() {
        cancelled = true; generation &+= 1
    }

    func beginAccountRemoteSuspension(_ application: SyncV2Application) async -> SyncV2AccountTransitionRemoteSuspensionToken {
        await application.beginAccountTransitionRemoteSuspension()
    }

    func endAccountRemoteSuspension(_: SyncV2Application, token _: SyncV2AccountTransitionRemoteSuspensionToken, resume _: Bool) async {}
    func accountCheckpoint(_ operation: @MainActor () async -> Bool) async -> Bool {
        core.inProgress = true
        defer { core.inProgress = false }
        guard fixture.prepare(leaseCount: leaseCount, session: session) else { return false }
        title = fixture.dirtyTitle
        return await operation()
    }

    func installAccountSession(_ session: FuminiwaSession?, state: WorkspaceAuthUIState) async {
        parked = session == nil || session?.accountID != fixture.first.accountID
        hasScopedUI = false
        authSession = session
        authUIState = state
    }

    func reloadAccountLibrary() async {}
    func resumeAccountWork() async {}
    func exchangeAccountSession(_ provider: AuthProvider) async throws -> FuminiwaSession {
        if provider == .apple {
            return try await fixture.orchestrator().signIn()
        }
        return try await fixture.coordinator.signInBrowser(provider: provider) { _ in }
    }

    func appleCredentialRevoked() async -> Bool {
        await (try? fixture.orchestrator().checkCredentialState()) == .revoked
    }

    func accountFailureMessage(_: any Error) -> String {
        "exchange failed"
    }

    func showRecoveredAccountFailure(_ message: String) {
        failureNotice = message
    }
}
