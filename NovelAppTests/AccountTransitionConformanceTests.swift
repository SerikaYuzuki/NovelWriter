@testable import EditorKit
import Foundation
@testable import FUMINIWA
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
@testable import NovelWorkspace
import NovelWorkspaceUI
import Testing

@Suite("macOS shared account transition conformance", .serialized)
struct MacAccountTransitionConformanceTests {
    @Test(arguments: AuthCharacterizationScenario.allCases)
    @MainActor
    func conformance(_ scenario: AuthCharacterizationScenario) async throws {
        let host = try await MacAccountTransitionHost.make(scenario)
        defer { host.cleanup() }
        try await AccountTransitionConformance.run(scenario, host: host)
    }
}

@MainActor
private final class MacAccountTransitionHost: AccountTransitionHost {
    let profile = AuthCharacterizationProfile.macOS
    let fixture: AccountTransitionFixture
    let state: AppState
    let configuration: TestRuntimeConfiguration
    let suite: String
    let workID: WorkID
    let workTask: Task<Void, Never>
    let aiKey: AssistantRequestKey

    private init(fixture: AccountTransitionFixture, state: AppState, configuration: TestRuntimeConfiguration, suite: String, workID: WorkID) {
        self.fixture = fixture; self.state = state; self.configuration = configuration
        self.suite = suite; self.workID = workID
        workTask = Task { try? await Task.sleep(for: .seconds(60)) }
        aiKey = AssistantRequestKey(work: workID.rawValue, account: "test-account", lane: "P10")
        fixture.editor.registerDocumentLifecycleHandler(id: UUID(), prepare: { [weak self] in
            guard let self else { return false }
            return fixture.prepare(leaseCount: leaseCount, session: session)
        }, resume: {})
    }

    static func make(_ scenario: AuthCharacterizationScenario) async throws -> MacAccountTransitionHost {
        let fixture = try AccountTransitionFixture(scenario: scenario, platform: .macos)
        let configuration = try TestRuntimeConfiguration()
        let suite = "FUMINIWA.P10Mac.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = AppState(dependencies: AppDependencies(
            userDefaults: defaults, editorCommandSession: fixture.editor,
            authSessionCoordinator: fixture.coordinator,
            appleAuthenticationOrchestrator: fixture.orchestrator(),
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }
        ))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let workID = try #require(state.currentSnapshotSyncV2WorkID)
        state.testServerInstanceIDOverride = "test-server"
        state.authSession = fixture.initialSession
        state.authUIState = fixture.initialSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        state.testBrowserAuthorization = { _ in }
        return MacAccountTransitionHost(fixture: fixture, state: state, configuration: configuration, suite: suite, workID: workID)
    }

    var session: FuminiwaSession? {
        state.authSession
    }

    var uiState: WorkspaceAuthUIState {
        state.authUIState
    }

    var scope: WorkspaceAccountScope {
        state.snapshotSyncV2AccountScopeToken
    }

    var leaseCount: Int {
        state.syncSessionController.remoteLeases.count
    }

    var hasScopedUI: Bool {
        state.snapshotSyncConflict != nil || state.snapshotSyncRemoteCatalogNextCursor != nil
    }

    var failureNotice: String? {
        state.operationMessage
    }

    var localOperationsAllowed: Bool {
        state.permitsDocumentTransitionOperation
    }

    func seedDirtyUIAndRequests() async {
        state.document.title = fixture.dirtyTitle
        state.markDocumentDirty()
        state.snapshotSyncConflict = authCharacterizationConflict()
        state.snapshotSyncRemoteCatalogNextCursor = "P10-old-cursor"
        state.libraryPrefetchTask = workTask
        let started = state.assistantRequestCenter.start(
            key: aiKey, timing: AssistantRuntimeTiming(defaults: state.userDefaults, purpose: .advice),
            operation: { _, _ in try await Task.sleep(for: .seconds(60)) }
        )
        #expect(started)
    }

    func restore() async {
        await state.restoreFuminiwaSession()
    }

    func signIn(_ provider: AuthProvider) async {
        if provider == .apple {
            await state.signInWithApple()
        } else {
            await state.signInWithGoogle()
        }
    }

    func signOut() async {
        await state.signOutFromFuminiwa()
    }

    func settleRevoke() async {}
    // macOS has no launch/foreground pending-revoke retry entry point today.
    func retryRevoke() async {}
    func transition(_ session: FuminiwaSession?) async -> Bool {
        await state.transitionFuminiwaSession(to: session, authState: session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut)
    }

    func persistedTitle() async throws -> String? {
        try await state.snapshotSyncV2Application?.openLocal(workID: workID).document?.title
    }

    func isWorkParked() async throws -> Bool {
        try await state.snapshotSyncV2Application?.library().items.first { $0.workID == workID }?.accountState == .parkedDifferentAccount
    }

    func requestsCancelled() async -> Bool {
        if workTask.isCancelled {
            try? await waitForAuthCharacterization { self.state.assistantRequestCenter.statuses[self.aiKey]?.inFlight == false }
        }
        return workTask.isCancelled && state.assistantRequestCenter.statuses[aiKey]?.inFlight == false
    }

    func cleanup() {
        workTask.cancel(); state.assistantRequestCenter.cancelAll()
        state.userDefaults.removePersistentDomain(forName: suite)
    }
}
