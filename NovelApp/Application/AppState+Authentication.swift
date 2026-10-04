import Foundation
import NovelAuth
import NovelAuthApple
import NovelSyncV2Application
import NovelWorkspace

extension AppState {
    private func authServerInstanceID(for session: FuminiwaSession) -> String {
        #if FUMINIWA_TEST_COMPOSITION
        testServerInstanceIDOverride ?? session.serverInstanceID.uuidString.lowercased()
        #else
        session.serverInstanceID.uuidString.lowercased()
        #endif
    }

    var isSignedInToFuminiwa: Bool {
        if case .signedIn = authUIState {
            return true
        }
        return false
    }

    var snapshotSyncV2AccountScopeToken: WorkspaceAccountScope {
        workspaceModel.accountScope(serverInstanceID: authSession.map { authServerInstanceID(for: $0) })
    }

    func matchesSnapshotSyncV2AccountScope(
        _ expected: WorkspaceAccountScope
    ) -> Bool {
        syncSessionController.matchesAccount(expected, current: snapshotSyncV2AccountScopeToken)
    }

    /// Cancels every asynchronous operation whose response could otherwise
    /// project or install bytes from the previous authenticated tenant.
    func invalidateSnapshotSyncV2AccountOperations() {
        clearKeepBothHandoff()
        assistantRequestCenter.cancelAll()
        libraryPrefetchTask?.cancel()
        libraryImportPhases.removeAll()
        libraryImportFailures.removeAll()
        snapshotSyncV2AccountScopeGeneration &+= 1
        snapshotSyncV2CatalogRefreshToken = nil
        cancelSnapshotSyncV2BackgroundOperations()
    }

    @discardableResult
    func transitionFuminiwaSession(to session: FuminiwaSession?, authState: AuthUIState, resumeRemoteAfterTransition: Bool = true) async -> Bool {
        await accountTransitionCoordinator.transition(to: session, state: authState, resumeRemote: resumeRemoteAfterTransition)
    }

    func restoreFuminiwaSession() async {
        await accountTransitionCoordinator.restore()
        resumePendingAuthRevoke()
    }

    @discardableResult
    func refreshFuminiwaSession() async -> Bool {
        await accountTransitionCoordinator.refresh()
    }

    func signInWithApple() async {
        if await accountTransitionCoordinator.signIn(.apple) {
            await refreshSnapshotRemoteCatalog()
        }
    }

    func signInWithGoogle() async {
        if await accountTransitionCoordinator.signIn(.google) {
            await refreshSnapshotRemoteCatalog()
        }
    }

    func signOutFromFuminiwa() async {
        await accountTransitionCoordinator.signOut()
    }

    func resumePendingAuthRevoke() {
        accountTransitionCoordinator.retryPendingRevoke()
    }

    /// Remote shelf/history/conflict state is scoped to the authenticated
    /// AccountID. Signing out must not leave the previous scope visible or
    /// make a later account switch look like an implicit adoption.
    private func clearAccountScopedSnapshotUI() {
        snapshotSyncRemoteCatalogItems = []
        snapshotSyncRemoteCatalogNextCursor = nil
        snapshotSyncLibraryFailure = nil
        snapshotSyncLibraryLocalFailure = nil
        snapshotSyncLibraryIsLoading = false
        snapshotSyncHistory = []
        snapshotSyncConflict = nil
        snapshotSyncV2UIState = nil
        snapshotSyncLibraryWorks = []
        snapshotSyncCurrentWorkAccountState = nil
        lastStartupLibraryConnection = .offline
        if !startupState.isReady {
            startupState = .documentSelection(
                .init(
                    works: [],
                    presentation: .localAndRemote,
                    connection: .offline
                )
            )
        }
    }
}

extension AppState: AccountTransitionPort {
    func canExchangeAccountSession(_: AuthProvider) -> Bool {
        authSessionCoordinator != nil
    }

    func accountBinding(_ session: FuminiwaSession) -> SyncV2AccountScopeBinding {
        SyncV2AccountScopeBinding(accountID: session.accountID, accountFence: session.accountFence,
                                  serverInstanceID: authServerInstanceID(for: session), protocolEpoch: Int64(session.syncProtocolEpoch))
    }

    func invalidateAccountOperations() {
        invalidateSnapshotSyncV2AccountOperations()
    }

    func beginAccountRemoteSuspension(_ application: SyncV2Application) async -> SyncV2AccountTransitionRemoteSuspensionToken {
        await syncSessionController.beginRemoteSuspension(application)
    }

    func endAccountRemoteSuspension(_ application: SyncV2Application, token: SyncV2AccountTransitionRemoteSuspensionToken, resume: Bool) async {
        _ = await syncSessionController.endRemoteSuspension(application, token: token, resume: resume)
    }

    func accountCheckpoint(_ operation: @MainActor () async -> Bool) async -> Bool {
        await documentOperationGate.perform {
            guard !self.isDocumentTransitionInProgress, self.editorCommandSession.prepareForDocumentTransition() else { return false }
            self.accountTransitionCoordinator.inProgress = true
            self.isDocumentTransitionInProgress = true
            defer {
                self.accountTransitionCoordinator.inProgress = false
                self.isDocumentTransitionInProgress = false
                self.editorCommandSession.resumeAfterDocumentTransition()
            }
            // Cold restore must reconcile persisted lanes before writing through
            // a destination vault. Dirty live work still checkpoints locally.
            let committedWithRetiredUI = self.saveState == .saving && !self.saveCoordinator.hasUnsavedChanges
            let shouldSave = self.currentSnapshotSyncV2WorkID != nil && self.saveState != .saved && !committedWithRetiredUI
            if shouldSave, await !self.saveNow() {
                return false
            }
            return await operation()
        }
    }

    func installAccountSession(_ session: FuminiwaSession?, state: WorkspaceAuthUIState) async {
        clearAccountScopedSnapshotUI()
        documentSessionToken = WorkspaceSessionToken(
            generation: documentSessionToken.generation &+ 1, documentID: document.id,
            workID: currentSnapshotSyncV2WorkID ?? documentSessionToken.workID
        )
        if let application = snapshotSyncV2Application, let workID = currentSnapshotSyncV2WorkID {
            snapshotSyncV2Session = await application.beginSession(workID: workID)
        }
        authSession = session
        authUIState = state
    }

    func reloadAccountLibrary() async {
        await refreshSnapshotLibrary()
    }

    func resumeAccountWork() async {
        guard !accountTransitionCoordinator.requested, authSession != nil else { return }
        try? await snapshotSyncV2Application?.resumePending()
        await resumeSnapshotSyncV2()
        await refreshSnapshotLibrary()
    }

    func exchangeAccountSession(_ provider: AuthProvider) async throws -> FuminiwaSession {
        guard let coordinator = authSessionCoordinator else { throw AuthError.restartAuthentication }
        #if FUMINIWA_TEST_COMPOSITION
        if provider == .apple, let orchestrator = appleAuthenticationOrchestrator {
            try await coordinator.beginFreshAppleAuthentication()
            return try await orchestrator.signIn()
        }
        #endif
        return try await coordinator.signInBrowser(provider: provider) { url in
            #if FUMINIWA_TEST_COMPOSITION
            if let authorize = self.testBrowserAuthorization {
                try await authorize(url)
                return
            }
            #endif
            try await self.browserAuthorization(url)
        }
    }

    func appleCredentialRevoked() async -> Bool {
        guard let orchestrator = appleAuthenticationOrchestrator else { return false }
        if await (try? authSessionCoordinator?.currentSession()?.receipt.commandKind) == "exchangeBrowserCredential" {
            return false
        }
        switch try? await orchestrator.checkCredentialState() {
        case .revoked?, .notFound?, .transferred?: return true
        default: return false
        }
    }

    func accountFailureMessage(_: any Error) -> String {
        "サインインできませんでした。接続を確認して、もう一度お試しください。"
    }

    func showRecoveredAccountFailure(_ message: String) {
        operationMessage = message
    }
}
