import Foundation
@testable import FUMINIWA
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Suite("macOS Snapshot Sync v2 account scope races")
struct SnapshotSyncV2MacAccountScopeTests {
    @Test("signout/account/fence transition parks the active Work but keeps local checkpointing")
    @MainActor
    func accountBoundaryPreservesParkedWorkLocally() async throws {
        let targets: [FuminiwaSession?] = [
            nil,
            makeMacV2Session(accountID: "account-b", fence: "fence-b"),
            makeMacV2Session(accountID: "account-a", fence: "fence-rotated")
        ]

        for target in targets {
            let configuration = try TestRuntimeConfiguration(
                account: TestAccount(accountID: "account-a", accountFence: "fence-a")
            )
            let defaults = try #require(
                UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacParked.\(UUID().uuidString)")
            )
            let state = AppState(
                dependencies: AppDependencies(
                    userDefaults: defaults,
                    snapshotSyncV2Factory: {
                        try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                    }
                )
            )
            #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
            await state.bootstrap()
            _ = await state.transitionFuminiwaSession(
                to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
                authState: .signedIn(accountID: "account-a")
            )
            let workID = try #require(state.currentSnapshotSyncV2WorkID)
            state.document.title = "変更前"
            state.markDocumentDirty()

            #expect(await state.transitionFuminiwaSession(
                to: target,
                authState: target.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
            ))
            if target == nil {
                let parked = try #require(
                    state.snapshotSyncLibraryWorks.first { $0.workID == workID }
                )
                #expect(parked.availability == .parked)
                #expect(parked.remoteProgress == .parkedDifferentAccount)
                #expect(parked.isOpenable)
            }
            state.document.title = "遷移後"
            state.markDocumentDirty()
            #expect(await state.saveNow())

            let reopened = try await state.snapshotSyncV2Application?.open(workID: workID)
            #expect(reopened?.document?.title == "遷移後")
            #expect(state.currentSnapshotSyncV2WorkID == workID)
        }
    }

    @Test("edits made while Apple sign-in is pending are checkpointed before reactivation")
    @MainActor
    func parkedEditSurvivesPendingAppleSignIn() async throws {
        let configuration = try TestRuntimeConfiguration(
            account: TestAccount(accountID: "account-a", accountFence: "fence-a")
        )
        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacAppleWait.\(UUID().uuidString)")
        )
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let session = makeMacV2Session(accountID: "account-a", fence: "fence-a")
        _ = await state.transitionFuminiwaSession(
            to: session,
            authState: .signedIn(accountID: session.accountID)
        )
        let workID = try #require(state.currentSnapshotSyncV2WorkID)

        state.document.title = "編集中"
        state.markDocumentDirty()
        #expect(await state.transitionFuminiwaSession(
            to: nil,
            authState: .signingIn,
            resumeRemoteAfterTransition: false
        ))
        #expect(state.permitsDocumentChoice)
        #expect(state.permitsDocumentTransitionOperation)
        #expect(state.permitsDocumentInteraction)

        // The editor remains available while Apple is awaiting a response.
        state.document.title = "Apple待機中の追加入力"
        state.markDocumentDirty()
        #expect(await state.transitionFuminiwaSession(
            to: session,
            authState: .signedIn(accountID: session.accountID),
            resumeRemoteAfterTransition: false
        ))
        #expect(state.currentSnapshotSyncV2WorkID == workID)
        #expect(state.document.title == "Apple待機中の追加入力")
        #expect(await configuration.remote.recordedOperations().isEmpty)

        let library = try #require(state.snapshotSyncV2Application)
        let projection = try await library.library()
        #expect(projection.items.contains { $0.workID == workID })
    }

    @Test("transient Apple credential lookup keeps the signed-in local scope")
    @MainActor
    func transientCredentialLookupDoesNotParkLocalWork() async throws {
        let session = makeMacV2Session(accountID: "account-a", fence: "fence-a")
        let configuration = try TestRuntimeConfiguration(
            account: TestAccount(accountID: session.accountID, accountFence: session.accountFence)
        )
        let authVault = InMemoryAuthSessionVault(session: session)
        let authLimits = try makeMacAuthTestLimits()
        let auth = AuthSessionCoordinator(
            transport: MacNoopAuthTransport(),
            vault: authVault,
            authLimits: authLimits
        )
        let handles = InMemoryAppleCredentialStateHandleVault()
        try await handles.save(
            "opaque-apple-handle",
            providerConfigurationID: "apple-primary-fuminiwa-v1"
        )
        let orchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: MacNoopAuthorizationProvider(),
            credentialStateHandleVault: handles,
            credentialStateProvider: MacTransientCredentialStateProvider()
        )
        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacCredentialTransient.\(UUID().uuidString)")
        )
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                authSessionCoordinator: auth,
                appleAuthenticationOrchestrator: orchestrator,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(
            to: session,
            authState: .signedIn(accountID: session.accountID)
        )
        let workID = try #require(state.currentSnapshotSyncV2WorkID)

        await state.restoreFuminiwaSession()

        #expect(state.authSession == session)
        #expect(state.authUIState == .signedIn(accountID: session.accountID))
        #expect(state.snapshotSyncLibraryWorks.contains { $0.workID == workID })
    }

    @Test("Apple sign-in keeps local replacement operations available while waiting")
    @MainActor
    func queuedAppleSignInKeepsDocumentReplacementBoundaryAvailable() async throws {
        let session = makeMacV2Session(accountID: "account-a", fence: "fence-a")
        let configuration = try TestRuntimeConfiguration(
            account: TestAccount(accountID: session.accountID, accountFence: session.accountFence)
        )
        let authLimits = try makeMacAuthTestLimits()
        let auth = AuthSessionCoordinator(
            transport: MacSignInTransport(session: session),
            vault: InMemoryAuthSessionVault(),
            authLimits: authLimits
        )
        let provider = MacWaitingAuthorizationProvider()
        let orchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: provider,
            credentialStateHandleVault: InMemoryAppleCredentialStateHandleVault(),
            credentialStateProvider: MacTransientCredentialStateProvider()
        )
        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacQueuedAuth.\(UUID().uuidString)")
        )
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                authSessionCoordinator: auth,
                appleAuthenticationOrchestrator: orchestrator,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FUMINIWA-pending-sign-in-" + UUID().uuidString + ".novelpkg",
                isDirectory: true
            )
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FUMINIWA-pending-sign-in-export-" + UUID().uuidString + ".novelpkg",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: exportURL)
        }
        try await NovelpkgRepository().save(
            NovelDocument.newDocument(title: "待機中に取り込む作品"),
            to: packageURL
        )

        let signingIn = Task { @MainActor in
            await state.signInWithApple()
        }
        try await eventuallyMac { provider.isWaiting }
        let providerFallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            provider.resume()
        }
        defer { providerFallback.cancel() }

        #expect(state.authUIState == AuthUIState.signingIn)
        #expect(state.permitsDocumentTransitionOperation)
        #expect(state.permitsDocumentInteraction)
        #expect(await state.createNewDocument())
        state.document.title = "待機中に作った作品"
        state.markDocumentDirty()
        #expect(await state.saveNow())
        let createdWorkID = try #require(state.currentSnapshotSyncV2WorkID)

        try await state.exportDocumentPackage(to: exportURL)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))

        #expect(await state.openDocument(at: packageURL))
        let openedWorkID = try #require(state.currentSnapshotSyncV2WorkID)
        #expect(openedWorkID != createdWorkID)
        #expect(state.document.title == "待機中に取り込む作品")

        #expect(await state.importExternalDocument(at: exportURL))
        let importedWorkID = try #require(state.currentSnapshotSyncV2WorkID)
        #expect(importedWorkID != openedWorkID)

        let application = try #require(state.snapshotSyncV2Application)
        let history = try await application.historyPage(workID: importedWorkID)
        let snapshotID = try #require(history.items.first?.snapshotID)
        #expect(await state.restoreSnapshotV2(snapshotID: snapshotID))
        #expect(await state.saveNow())
        let currentWorkID = try #require(state.currentSnapshotSyncV2WorkID)
        let currentTitle = state.document.title

        provider.resume()
        await signingIn.value
        #expect(state.interactiveAuthOperationCount == 0)
        #expect(state.permitsDocumentTransitionOperation)
        #expect(state.authSession?.accountID == session.accountID)
        // The delayed auth result may rebind parked rows, but it cannot adopt
        // or overwrite a Work opened locally while the exchange was waiting.
        #expect(state.currentSnapshotSyncV2WorkID == currentWorkID)
        #expect(state.document.title == currentTitle)
    }

    @Test("signout releases local document transitions before a suspended remote revoke")
    @MainActor
    func signOutReleasesDocumentBoundaryBeforeRemoteRevoke() async throws {
        let session = makeMacV2Session(accountID: "account-a", fence: "fence-a")
        let configuration = try TestRuntimeConfiguration(
            account: TestAccount(accountID: session.accountID, accountFence: session.accountFence)
        )
        let revokeTransport = SuspendedMacRevokeTransport(session: session)
        let authLimits = try makeMacAuthTestLimits()
        let auth = AuthSessionCoordinator(
            transport: revokeTransport,
            vault: InMemoryAuthSessionVault(session: session),
            authLimits: authLimits
        )
        let signInProvider = MacWaitingAuthorizationProvider()
        let orchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: signInProvider,
            credentialStateHandleVault: InMemoryAppleCredentialStateHandleVault(),
            credentialStateProvider: MacTransientCredentialStateProvider()
        )
        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacSuspendedRevoke.\(UUID().uuidString)")
        )
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                authSessionCoordinator: auth,
                appleAuthenticationOrchestrator: orchestrator,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(
            to: session,
            authState: .signedIn(accountID: session.accountID)
        )
        let originalWorkID = try #require(state.currentSnapshotSyncV2WorkID)
        let queuedOpenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FUMINIWA-queued-revoke-open-" + UUID().uuidString + ".novelpkg",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: queuedOpenURL) }
        try await NovelpkgRepository().save(
            NovelDocument.newDocument(title: "revoke中に開く作品"),
            to: queuedOpenURL
        )

        state.document.title = "remote revoke 待機前"
        state.markDocumentDirty()
        let signingOut = Task { @MainActor in
            await state.signOutFromFuminiwa()
        }
        try await eventuallyMac {
            await revokeTransport.isWaiting
        }

        // Durable parking is complete before the server revoke is released.
        #expect(state.authSession == nil)
        #expect(state.interactiveAuthOperationCount == 0)
        #expect(state.permitsDocumentTransitionOperation)
        #expect(state.permitsDocumentInteraction)
        #expect(state.snapshotSyncV2ActiveWorkID == originalWorkID)
        #expect(state.snapshotSyncLibraryWorks.contains {
            $0.workID == originalWorkID && $0.remoteProgress == .parkedDifferentAccount
        })

        // Local operations remain available while the revoke is offline; the
        // active suspension prevents these checkpoints from sending remotely.
        state.document.title = "revoke 待機中の追加入力"
        state.markDocumentDirty()
        #expect(await state.saveNow())
        #expect(await state.createNewDocument())
        #expect(state.permitsDocumentTransitionOperation)
        #expect(await configuration.remote.recordedOperations().isEmpty)

        // A new auth request is queued behind the revoke rather than racing
        // the vault. The request is queued without blocking local work.
        let signingIn = Task { @MainActor in
            await state.signInWithApple()
        }
        let duplicateSigningIn = Task { @MainActor in
            await state.signInWithApple()
        }
        let signInProviderFallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            signInProvider.resume()
        }
        defer { signInProviderFallback.cancel() }
        #expect(state.interactiveAuthOperationCount == 0)
        #expect(await state.createNewDocument())
        #expect(await state.openDocument(at: queuedOpenURL))
        #expect(await state.saveNow())
        #expect(state.interactiveAuthOperationCount == 0)
        #expect(!signInProvider.isWaiting)
        #expect(state.authUIState == .signedOut)

        await revokeTransport.resume()
        await signingOut.value
        try await eventuallyMac { signInProvider.isWaiting }
        #expect(signInProvider.authorizationCallCount == 1)
        signInProvider.resume()
        await signingIn.value
        await duplicateSigningIn.value
        #expect(state.interactiveAuthOperationCount == 0)
        #expect(state.authUIState == .signedIn(accountID: session.accountID))
    }
}

@Suite("macOS Snapshot Sync v2 account scope completion races")
struct SnapshotSyncV2MacAccountCompletionTests {
    @Test("old account catalog completion cannot repopulate the new account shelf")
    @MainActor
    func catalogCompletionIsRejectedAfterAccountSwitch() async throws {
        let suspendedCatalog = SuspendedMacCatalog()
        var dependencies = try makeAccountScopeDependencies()
        dependencies.snapshotSyncV2CatalogOverride = { _, cursor, _ in
            await suspendedCatalog.page(cursor: cursor)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )

        let refresh = Task { @MainActor in
            await state.refreshSnapshotRemoteCatalog()
        }
        try await eventuallyMac {
            await suspendedCatalog.isWaiting
        }

        _ = await state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
            authState: .signedIn(accountID: "account-b")
        )
        let staleWorkID = WorkID(UUID())
        await suspendedCatalog.resume(
            with: SyncV2RemoteCatalogPage(
                items: [
                    SyncV2RemoteCatalogEntry(
                        workID: staleWorkID,
                        title: "旧アカウント作品",
                        head: nil
                    )
                ],
                nextCursor: nil
            )
        )
        await refresh.value

        #expect(state.authSession?.accountID == "account-b")
        #expect(state.snapshotSyncRemoteCatalogItems.isEmpty)
        #expect(state.snapshotSyncLibraryWorks.allSatisfy { $0.workID != staleWorkID })
    }

    @Test("old account remote-only download cannot install into the editor")
    @MainActor
    func remoteOnlyCompletionIsRejectedAfterAccountSwitch() async throws {
        let suspendedOpen = SuspendedMacAccountOpen()
        var dependencies = try makeAccountScopeDependencies()
        dependencies.snapshotSyncV2OpenOverride = { _, workID in
            await suspendedOpen.open(workID: workID)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )
        let originalWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let originalSession = state.documentSessionToken
        let originalDocument = state.document
        let remoteWorkID = WorkID(UUID())
        let remoteWork = StartupLibraryWork(
            id: remoteWorkID.rawValue,
            title: "旧アカウントの取得作品",
            availability: .remoteOnly,
            workID: remoteWorkID,
            remoteProgress: .idle
        )
        state.snapshotSyncLibraryWorks = [remoteWork]

        #expect(await state.openLibraryWork(remoteWork))
        try await eventuallyMac {
            await suspendedOpen.isWaiting(for: remoteWorkID)
        }
        let accountSwitch = Task { @MainActor in
            _ = await state.transitionFuminiwaSession(
                to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
                authState: .signedIn(accountID: "account-b")
            )
        }
        await suspendedOpen.resume(
            returning: SyncV2OpenedWork(
                workID: remoteWorkID,
                document: NovelDocument.newDocument(title: "届いてはいけない作品"),
                documentCreatedAt: Date(),
                generation: 1,
                snapshotID: nil
            )
        )
        _ = await accountSwitch.value
        try await eventuallyMac {
            state.snapshotSyncV2RemoteOnlyOpenTask == nil
        }

        #expect(state.authSession?.accountID == "account-b")
        #expect(state.snapshotSyncV2ActiveWorkID == originalWorkID)
        #expect(state.documentSessionToken != originalSession)
        #expect(state.document == originalDocument)
        #expect(state.operationMessage == nil)
    }

    @Test("old account local shelf open cannot install into the editor")
    @MainActor
    func localOpenCompletionIsRejectedAfterAccountSwitch() async throws {
        let suspendedOpen = SuspendedMacAccountOpen()
        var dependencies = try makeAccountScopeDependencies()
        dependencies.snapshotSyncV2OpenLocalOverride = { _, workID in
            await suspendedOpen.open(workID: workID)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )
        let originalWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let originalSession = state.documentSessionToken
        let originalDocument = state.document
        let localWorkID = WorkID(UUID())
        let localWork = StartupLibraryWork(
            id: localWorkID.rawValue,
            title: "旧アカウントの端末作品",
            availability: .local,
            workID: localWorkID,
            remoteProgress: .idle
        )

        let opening = Task { @MainActor in
            await state.openLibraryWork(localWork)
        }
        try await eventuallyMac {
            await suspendedOpen.isWaiting(for: localWorkID)
        }
        let accountSwitch = Task { @MainActor in
            _ = await state.transitionFuminiwaSession(
                to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
                authState: .signedIn(accountID: "account-b")
            )
        }
        await suspendedOpen.resume(
            returning: SyncV2OpenedWork(
                workID: localWorkID,
                document: NovelDocument.newDocument(title: "届いてはいけない端末作品"),
                documentCreatedAt: Date(),
                generation: 1,
                snapshotID: nil
            )
        )
        _ = await accountSwitch.value
        try await eventuallyMac { state.authSession?.accountID == "account-b" }

        #expect(await opening.value == false)
        #expect(state.authSession?.accountID == "account-b")
        #expect(state.snapshotSyncV2ActiveWorkID == originalWorkID)
        #expect(state.documentSessionToken != originalSession)
        #expect(state.document == originalDocument)
        #expect(state.operationMessage == nil)
    }
}

@MainActor
func makeMacV2Session(accountID: String, fence: String) -> FuminiwaSession {
    let now = Date()
    return FuminiwaSession(
        binding: AuthSessionBinding(
            serverInstanceID: UUID(),
            syncProtocolEpoch: 2,
            accountID: accountID,
            accountAuthEpoch: 1,
            accountFence: fence,
            sessionID: UUID()
        ),
        tokens: AuthSessionTokens(
            accessToken: "test-access-\(accountID)",
            accessTokenExpiresAt: now.addingTimeInterval(3600),
            refreshToken: "test-refresh-\(accountID)",
            refreshTokenExpiresAt: now.addingTimeInterval(86400),
            refreshGeneration: 1
        ),
        receipt: AuthReceipt(
            commandKind: "appleExchange",
            operationID: UUID(),
            replayUntil: now.addingTimeInterval(300)
        )
    )
}

@MainActor
private func makeAccountScopeDependencies() throws -> AppDependencies {
    let configuration = try TestRuntimeConfiguration()
    let defaults = try #require(
        UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacAccountScopeTests.\(UUID().uuidString)")
    )
    return AppDependencies(
        userDefaults: defaults,
        snapshotSyncV2Factory: {
            try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        }
    )
}

private actor SuspendedMacCatalog {
    private var continuation: CheckedContinuation<SyncV2RemoteCatalogPage, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func page(cursor _: String?) async -> SyncV2RemoteCatalogPage {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with page: SyncV2RemoteCatalogPage) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: page)
    }
}

private actor SuspendedMacAccountOpen {
    private var waitingWorkID: WorkID?
    private var continuation: CheckedContinuation<SyncV2OpenedWork, Never>?

    func open(workID: WorkID) async -> SyncV2OpenedWork {
        waitingWorkID = workID
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting(for workID: WorkID) -> Bool {
        waitingWorkID == workID && continuation != nil
    }

    func resume(returning opened: SyncV2OpenedWork) {
        waitingWorkID = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: opened)
    }
}

private actor SuspendedMacRevokeTransport: FuminiwaAuthTransport {
    private let signInSession: FuminiwaSession?
    private var continuation: CheckedContinuation<Void, Never>?

    init(session: FuminiwaSession? = nil) {
        signInSession = session
    }

    var isWaiting: Bool {
        continuation != nil
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge {
        guard signInSession != nil else { throw AuthError.providerRejected }
        let now = Date()
        return AuthChallenge(
            challengeID: UUID(),
            expiresAt: now.addingTimeInterval(300),
            audience: "dev.serikayuzuki.fuminiwa",
            providerConfigurationID: "apple-primary-fuminiwa-v1",
            state: String(repeating: "A", count: 43),
            nonce: String(repeating: "B", count: 43),
            receipt: AuthReceipt(
                commandKind: "createChallenge",
                operationID: operationID,
                replayUntil: now.addingTimeInterval(3600)
            )
        )
    }

    func exchangeApple(
        challenge _: AuthChallenge,
        authorizationCode _: Data,
        identityToken _: Data,
        operationID _: UUID
    ) async throws -> FuminiwaSession {
        guard let signInSession else { throw AuthError.providerRejected }
        return signInSession
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private struct MacNoopAuthTransport: FuminiwaAuthTransport {
    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }
}

@MainActor
private final class MacNoopAuthorizationProvider: AppleAuthorizationProviding {
    func authorize(using _: AuthChallenge) async throws -> AppleAuthorizationPayload {
        throw AuthError.providerRejected
    }
}

private actor MacTransientCredentialStateProvider: AppleCredentialStateProviding {
    func credentialState(for _: String) async throws -> AppleCredentialState {
        throw AuthError.providerRejected
    }
}

@MainActor
private final class MacWaitingAuthorizationProvider: AppleAuthorizationProviding {
    private var continuation: CheckedContinuation<AppleAuthorizationPayload, Never>?
    private(set) var isWaiting = false
    private(set) var authorizationCallCount = 0

    func authorize(using _: AuthChallenge) async throws -> AppleAuthorizationPayload {
        authorizationCallCount += 1
        isWaiting = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        isWaiting = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(
            returning: AppleAuthorizationPayload(
                userHandle: "opaque-apple-handle",
                authorizationCode: Data("apple-code".utf8),
                identityToken: Data("header.payload.signature".utf8)
            )
        )
    }
}

private actor MacSignInTransport: FuminiwaAuthTransport {
    let session: FuminiwaSession

    init(session: FuminiwaSession) {
        self.session = session
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge {
        let now = Date()
        return AuthChallenge(
            challengeID: UUID(),
            expiresAt: now.addingTimeInterval(300),
            audience: "dev.serikayuzuki.fuminiwa",
            providerConfigurationID: "apple-primary-fuminiwa-v1",
            state: String(repeating: "A", count: 43),
            nonce: String(repeating: "B", count: 43),
            receipt: AuthReceipt(
                commandKind: "createChallenge",
                operationID: operationID,
                replayUntil: now.addingTimeInterval(3600)
            )
        )
    }

    func exchangeApple(
        challenge _: AuthChallenge,
        authorizationCode _: Data,
        identityToken _: Data,
        operationID _: UUID
    ) async throws -> FuminiwaSession {
        session
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }
}

private func makeMacAuthTestLimits() throws -> AuthLimits {
    try AuthLimits(
        accessTokenLifetimeSeconds: 900,
        authReceiptLifetimeSeconds: 86400,
        challengeLifetimeSeconds: 300,
        maxCanonicalCommandBytes: 65536,
        maxProviderClockSkewSeconds: 300,
        refreshTokenLifetimeSeconds: 86400
    )
}
