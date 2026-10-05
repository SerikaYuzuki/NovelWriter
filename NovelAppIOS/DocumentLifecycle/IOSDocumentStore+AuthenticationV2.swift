import Foundation
import NovelAuth
import NovelAuthApple
import NovelSyncV2Application
import NovelWorkspace

private enum IOSDocumentStoreAuthenticationError: Error { case unavailable }

extension IOSDocumentStore {
    @discardableResult
    func transitionFuminiwaSession(to session: FuminiwaSession?, authState: IOSAuthUIState, requestOwner: UUID? = nil) async -> Bool {
        await accountTransitionCoordinator.transition(to: session, state: authState, owner: requestOwner)
    }

    func restoreFuminiwaSession() async {
        await accountTransitionCoordinator.restore()
    }

    @discardableResult
    func refreshFuminiwaSession() async -> Bool {
        await accountTransitionCoordinator.refresh()
    }

    func signInWithApple() async {
        await accountTransitionCoordinator.signIn(.apple)
    }

    func signInWithGoogle() async {
        await accountTransitionCoordinator.signIn(.google)
    }

    func signOutFromFuminiwa() async {
        await accountTransitionCoordinator.signOut()
    }

    func resumePendingAuthRevoke() {
        accountTransitionCoordinator.retryPendingRevoke()
    }

    private func exchangeAppleSession() async throws -> FuminiwaSession {
        #if FUMINIWA_TEST_COMPOSITION
        if let testAppleSignInHandler {
            return try await testAppleSignInHandler()
        }
        #endif
        guard let appleAuthenticationOrchestrator else {
            throw IOSDocumentStoreAuthenticationError.unavailable
        }
        // A new native authorization is an explicit recovery choice after a
        // cold restart. Raw Apple credentials are not persisted, so an old
        // exchange journal would otherwise block the fresh challenge. The
        // same-call indeterminate/lost-ACK replay bypasses this method and
        // retries the original operation directly.
        guard let authSessionCoordinator else {
            throw IOSDocumentStoreAuthenticationError.unavailable
        }
        try await authSessionCoordinator.beginFreshAppleAuthentication()
        return try await appleAuthenticationOrchestrator.signIn()
    }

    func exchangeAccountSession(_ provider: AuthProvider) async throws -> FuminiwaSession {
        if provider == .apple {
            return try await exchangeAppleSession()
        }
        guard let coordinator = authSessionCoordinator else { throw IOSDocumentStoreAuthenticationError.unavailable }
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

    private func clearAccountScopedSnapshotUIForIOS() {
        workspaceModel.remoteDeletedWorkIDs = []
        workspaceModel.trashLocalItems = []
        workspaceModel.removedTrashCopyIDs = []
        workspaceModel.libraryRefreshNotice = nil
        workspaceModel.remoteCatalogItems = []
        workspaceModel.remoteCatalogCursor = nil
        syncV2RemoteCatalogError = nil
        workspaceModel.libraryFailure = nil
        libraryNotice = nil
        snapshotSyncV2RemoteOnlyOpenFailure = nil
        workspaceModel.historyItems = []
        syncV2HistoryCursor = nil
        syncV2HistoryWorkID = nil
        syncV2HistoryLocalAvailability = .unavailable
        syncV2HistoryOnlineAvailability = .unavailable
        syncV2HistoryOnlineFailure = nil
        workspaceModel.syncConflict = nil
        workspaceModel.syncUIState = nil
        snapshotSyncOutcome = .failure(.offline)
    }

    private func retainLocalOnlyIOSLibraryProjection() {
        workspaceModel.libraryRows = workspaceModel.libraryRows.filter {
            $0.accountState == .unbound || $0.accountState == .parkedDifferentAccount
        }
    }

    func flushDeviceSyncForBackground(waitForRemote _: Bool) async -> Bool {
        _ = await saveNow()
        Task { await resumeSnapshotSyncV2() }
        return workspaceModel.saveState == .saved
    }

    func captureAutomaticSnapshotForBackground() async {}

    func flushDeviceSyncBeforeNavigationDeparture(
        _ departure: IOSWorkspaceEditorDeparture
    ) async -> Bool {
        guard currentDocumentSessionToken == departure.session else { return true }
        guard editorCommandSession.prepareForDocumentTransition() else {
            operationErrorMessage = "日本語入力を確定できませんでした。"
            return false
        }
        defer { editorCommandSession.resumeAfterDocumentTransition() }
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            if let chapterID = departure.chapterID, let episodeID = departure.episodeID {
                updateEpisodeContent(text, chapterID: chapterID, episodeID: episodeID)
            }
        case .compositionInProgress:
            operationErrorMessage = "日本語入力を確定できませんでした。"
            return false
        case .notActive: break
        }
        return await ConflictCoordinator.saveBeforeDeparture(
            currentWorkID: workspaceModel.activeWorkID, pendingDuplicateID: workspaceModel.keepBothPendingWorkID,
            save: { await self.saveNow() }
        )
    }

    func prepareForEditorSurfaceDeparture(clearProofreadingHighlights: Bool = false) async -> Bool {
        let editingToken = currentEpisodeEditingToken
        let account = snapshotSyncV2AccountScope
        guard editorCommandSession.prepareForDocumentTransition() else { return false }
        defer { editorCommandSession.resumeAfterDocumentTransition() }
        let saved = await saveNow()
        if saved, clearProofreadingHighlights, currentEpisodeEditingToken == editingToken,
           matchesSyncAccount(account) {
            editorCommandSession.clearProofreadingHighlights()
        }
        return saved
    }
}

extension IOSDocumentStore: AccountTransitionPort {
    func canExchangeAccountSession(_ provider: AuthProvider) -> Bool {
        #if FUMINIWA_TEST_COMPOSITION
        if provider == .apple, testAppleSignInHandler != nil {
            return true
        }
        #endif
        return provider == .apple ? appleAuthenticationOrchestrator != nil : authSessionCoordinator != nil
    }

    func accountBinding(_ session: FuminiwaSession) -> SyncV2AccountScopeBinding {
        let server: String
        #if FUMINIWA_TEST_COMPOSITION
        server = testServerInstanceIDOverride ?? session.serverInstanceID.uuidString.lowercased()
        #else
        server = session.serverInstanceID.uuidString.lowercased()
        #endif
        return SyncV2AccountScopeBinding(accountID: session.accountID, accountFence: session.accountFence,
                                         serverInstanceID: server, protocolEpoch: Int64(session.syncProtocolEpoch))
    }

    func invalidateAccountOperations() {
        cancelSnapshotSyncV2BackgroundOperations()
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
            guard !self.workspaceModel.isDocumentTransitionInProgress else { return false }
            self.accountTransitionCoordinator.inProgress = true
            defer { self.accountTransitionCoordinator.inProgress = false }
            guard await self.performDocumentTransition({}) else { return false }
            return await operation()
        }
    }

    func installAccountSession(_ session: FuminiwaSession?, state: WorkspaceAuthUIState) async {
        let previous = workspaceModel.authSession
        dismissExport()
        clearAccountScopedSnapshotUIForIOS()
        syncV2ParkedAccountID = session == nil ? previous?.accountID : nil
        if session == nil {
            retainLocalOnlyIOSLibraryProjection()
        }
        workspaceModel.authSession = session
        workspaceModel.authUIState = state
    }

    func reloadAccountLibrary() async {
        _ = try? await reloadLibraryItems()
    }

    func resumeAccountWork() async {
        guard !isSyncV2RemoteAccountTransitionActive, workspaceModel.authSession != nil,
              let application = snapshotSyncV2Application else { return }
        let expected = snapshotSyncV2AccountScope
        try? await application.resumePending()
        await resumeSnapshotSyncV2()
        guard matchesLocalSyncAccount(expected) else { return }
        _ = await refreshRemoteCatalog(reset: true)
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

    func accountFailureMessage(_ error: any Error) -> String {
        appleSignInFailureMessage(error)
    }

    func showRecoveredAccountFailure(_ message: String) {
        operationErrorMessage = message
    }
}
