@testable import EditorKit
import Foundation
@testable import FUMINIWAIOS
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
@testable import NovelWorkspace
import NovelWorkspaceUI
import Testing

@Suite("iOS shared account transition conformance", .serialized)
struct IOSAccountTransitionConformanceTests {
    @Test(arguments: AuthCharacterizationScenario.allCases)
    @MainActor
    func conformance(_ scenario: AuthCharacterizationScenario) async throws {
        let host = try await IOSAccountTransitionHost.make(scenario)
        defer { host.cleanup() }
        try await AccountTransitionConformance.run(scenario, host: host)
    }
}

@MainActor
private final class IOSAccountTransitionHost: AccountTransitionHost {
    let fixture: AccountTransitionFixture
    let state: IOSDocumentStore
    let configuration: TestRuntimeConfiguration
    let suite: String
    let workID: WorkID
    let workTask: Task<Void, Never>
    let aiKey: AssistantRequestKey

    private init(fixture: AccountTransitionFixture, state: IOSDocumentStore, configuration: TestRuntimeConfiguration, suite: String, workID: WorkID) {
        self.fixture = fixture; self.state = state; self.configuration = configuration
        self.suite = suite; self.workID = workID
        workTask = Task { try? await Task.sleep(for: .seconds(60)) }
        aiKey = AssistantRequestKey(work: workID.rawValue, account: "test-account", lane: "P10")
        fixture.editor.registerDocumentLifecycleHandler(id: UUID(), prepare: { [weak self] in
            guard let self else { return false }
            return fixture.prepare(leaseCount: leaseCount, session: session)
        }, resume: {})
    }

    static func make(_ scenario: AuthCharacterizationScenario) async throws -> IOSAccountTransitionHost {
        let fixture = try AccountTransitionFixture(scenario: scenario, platform: .ios)
        let configuration = try TestRuntimeConfiguration()
        let suite = "FUMINIWA.P10IOS.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = IOSDocumentStore(
            userDefaults: defaults, editorCommandSession: fixture.editor,
            libraryRoot: configuration.localRoot.url, runtimeComposition: .test(configuration)
        )
        #expect(await state.configureSnapshotSyncV2())
        await state.bootstrap()
        #expect(await state.makeNewDocument())
        let workID = try #require(state.syncV2ActiveWorkID)
        state.authSessionVault = fixture.vault
        state.authSessionCoordinator = fixture.coordinator
        state.appleAuthenticationOrchestrator = fixture.orchestrator()
        state.testServerInstanceIDOverride = "test-server"
        state.authSession = fixture.initialSession
        state.authUIState = fixture.initialSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        state.testBrowserAuthorization = { _ in }
        return IOSAccountTransitionHost(fixture: fixture, state: state, configuration: configuration, suite: suite, workID: workID)
    }

    var session: FuminiwaSession? {
        state.authSession
    }

    var uiState: WorkspaceAuthUIState {
        state.authUIState
    }

    var scope: WorkspaceAccountScope {
        state.snapshotSyncV2AccountScope
    }

    var leaseCount: Int {
        state.syncSessionController.remoteLeases.count
    }

    var hasScopedUI: Bool {
        state.snapshotSyncConflict != nil || state.syncV2RemoteCatalogCursor != nil
    }

    var failureNotice: String? {
        state.operationErrorMessage
    }

    var localOperationsAllowed: Bool {
        !state.isDocumentTransitionInProgress && !state.syncV2AccountTransitionInProgress
    }

    func seedDirtyUIAndRequests() async {
        state.updateDocumentTitle(fixture.dirtyTitle)
        state.snapshotSyncConflict = authCharacterizationConflict()
        state.syncV2RemoteCatalogCursor = "P10-old-cursor"
        state.libraryPrefetchTask = workTask
        let started = state.assistantRequestCenter.start(
            key: aiKey, timing: AssistantRuntimeTiming(defaults: state.userDefaults, purpose: .advice),
            operation: { _, _ in try await Task.sleep(for: .seconds(60)) }
        )
        #expect(started)
    }

    func refresh() async -> Bool {
        await state.refreshFuminiwaSession()
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

    func settleRevoke() async {
        await state.authRevokeRetryTask?.value
    }

    func retryRevoke() async {
        state.resumePendingAuthRevoke(); await settleRevoke()
    }

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
        IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: configuration.localRoot.url.standardizedFileURL)
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: configuration.localRoot.url.standardizedFileURL)
    }
}
