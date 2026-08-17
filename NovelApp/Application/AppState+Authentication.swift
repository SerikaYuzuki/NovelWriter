import Foundation
import NovelAuth
import NovelSyncV2Application

extension AppState {
    var isSignedInToFuminiwa: Bool {
        if case .signedIn = authUIState {
            return true
        }
        return false
    }

    var snapshotSyncV2AccountScopeToken: SnapshotSyncV2AccountScopeToken {
        SnapshotSyncV2AccountScopeToken(
            accountID: authSession?.accountID,
            accountFence: authSession?.accountFence,
            generation: snapshotSyncV2AccountScopeGeneration
        )
    }

    func matchesSnapshotSyncV2AccountScope(
        _ expected: SnapshotSyncV2AccountScopeToken
    ) -> Bool {
        snapshotSyncV2AccountScopeToken == expected
    }

    /// Cancels every asynchronous operation whose response could otherwise
    /// project or install bytes from the previous authenticated tenant.
    func invalidateSnapshotSyncV2AccountOperations() {
        snapshotSyncV2AccountScopeGeneration &+= 1
        snapshotSyncV2CatalogRefreshToken = nil
        cancelSnapshotSyncV2BackgroundOperations()
    }

    /// Installs a server-verified session without treating ordinary access
    /// token refresh as an account switch. Tests use the same boundary to
    /// exercise AccountID/fence races without bypassing production behavior.
    @discardableResult
    func transitionFuminiwaSession(
        to session: FuminiwaSession?,
        authState: AuthUIState
    ) async -> Bool {
        let scopeChanged = authSession?.accountID != session?.accountID
            || authSession?.accountFence != session?.accountFence
        guard scopeChanged else {
            if authSession == nil, session == nil {
                // Even a nil-to-nil sign-out is an ownership change for an
                // in-flight restore/sign-in result.
                invalidateSnapshotSyncV2AccountOperations()
            }
            authSession = session
            authUIState = authState
            return true
        }

        // Retire in-flight completions before waiting for the document gate.
        // The gate still owns the durable checkpoint and auth replacement, but
        // a suspended open/download must fail its stale-session check rather
        // than hold the transition behind an external await.
        invalidateSnapshotSyncV2AccountOperations()
        let requestGeneration = snapshotSyncV2AccountScopeGeneration
        let transitioned = await documentOperationGate.perform { [weak self] in
            guard let self,
                  snapshotSyncV2AccountScopeGeneration == requestGeneration,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }

            let oldSession = authSession
            let oldWorkID = currentSnapshotSyncV2WorkID
            var checkpointed = saveState == .saved || oldWorkID == nil
            if !checkpointed {
                checkpointed = await saveNow()
            }

            // An external auth refresh may have already replaced the vault
            // before this UI session noticed it. Park first and retry the
            // local checkpoint through the now-unbound authority in that
            // narrow recovery case; never discard the in-memory editor.
            if let oldSession, let oldWorkID, let application = snapshotSyncV2Application {
                let oldBinding = SyncV2AccountScopeBinding(
                    accountID: oldSession.accountID,
                    accountFence: oldSession.accountFence,
                    serverInstanceID: oldSession.serverInstanceID.uuidString.lowercased(),
                    protocolEpoch: Int64(oldSession.syncProtocolEpoch)
                )
                do {
                    if let session, session.accountID == oldSession.accountID {
                        let newBinding = SyncV2AccountScopeBinding(
                            accountID: session.accountID,
                            accountFence: session.accountFence,
                            serverInstanceID: session.serverInstanceID.uuidString.lowercased(),
                            protocolEpoch: Int64(session.syncProtocolEpoch)
                        )
                        try await application.rebindAccountScope(
                            workID: oldWorkID,
                            from: oldBinding,
                            to: newBinding
                        )
                    } else {
                        try await application.parkAccountScope(
                            workID: oldWorkID,
                            binding: oldBinding
                        )
                    }
                } catch {
                    // Parking/quarantining is part of the auth transition.
                    // A failure leaves the old editor, shelf, and auth state
                    // untouched; never silently continue with a new session.
                    return false
                }
            }

            guard checkpointed else { return false }
            clearAccountScopedSnapshotUI()
            documentSessionToken = AppDocumentSessionToken(
                generation: documentSessionToken.generation &+ 1,
                documentID: document.id,
                workID: currentSnapshotSyncV2WorkID ?? documentSessionToken.workID
            )
            if let application = snapshotSyncV2Application, let workID = currentSnapshotSyncV2WorkID {
                snapshotSyncV2Session = await application.beginSession(workID: workID)
            }
            authSession = session
            authUIState = authState
            return true
        }
        guard transitioned else { return false }
        // Reproject local parked work immediately. This is deliberately after
        // the gate so the shelf cannot observe a half-completed transition.
        await refreshSnapshotLibrary()
        return true
    }

    /// Credential-state lookup is advisory.  It may fail offline without
    /// blocking the local SQLite workbench.
    func restoreFuminiwaSession() async {
        let requestGeneration = snapshotSyncV2AccountScopeGeneration
        guard let coordinator = authSessionCoordinator else {
            authUIState = .unavailable
            return
        }
        do {
            if let orchestrator = appleAuthenticationOrchestrator {
                switch try await orchestrator.checkCredentialState() {
                case .revoked?, .notFound?, .transferred?:
                    guard snapshotSyncV2AccountScopeGeneration == requestGeneration else { return }
                    _ = await transitionFuminiwaSession(to: nil, authState: .signedOut)
                    return
                default:
                    break
                }
            }
            let session = try await coordinator.currentSession()
            guard snapshotSyncV2AccountScopeGeneration == requestGeneration else { return }
            _ = await transitionFuminiwaSession(
                to: session,
                authState: session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
            )
        } catch {
            guard snapshotSyncV2AccountScopeGeneration == requestGeneration else { return }
            _ = await transitionFuminiwaSession(
                to: nil,
                authState: .failed("サインイン状態を復元できませんでした")
            )
        }
    }

    func signInWithApple() async {
        guard let orchestrator = appleAuthenticationOrchestrator else {
            authUIState = .unavailable
            return
        }
        guard authUIState != .signingIn else { return }
        // The Apple exchange persists the new vault session before returning.
        // Retire the old binding first so its dirty editor can never be
        // checkpointed against the new account's scope.
        guard await transitionFuminiwaSession(to: nil, authState: .signingIn) else { return }
        authUIState = .signingIn
        let requestGeneration = snapshotSyncV2AccountScopeGeneration
        do {
            // The orchestrator exchanges the one-use Apple credential with the
            // auth server. The Apple token is never passed to Snapshot Sync.
            let session = try await orchestrator.signIn()
            guard snapshotSyncV2AccountScopeGeneration == requestGeneration else { return }
            guard await transitionFuminiwaSession(
                to: session,
                authState: .signedIn(accountID: session.accountID)
            ) else { return }
            await resumeSnapshotSyncV2()
            await refreshSnapshotLibrary()
            await refreshSnapshotRemoteCatalog()
        } catch is CancellationError {
            guard snapshotSyncV2AccountScopeGeneration == requestGeneration else { return }
            authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        } catch {
            guard snapshotSyncV2AccountScopeGeneration == requestGeneration else { return }
            authUIState = .failed("Appleでのサインインを完了できませんでした")
        }
    }

    func signOutFromFuminiwa() async {
        guard await transitionFuminiwaSession(
            to: nil,
            authState: authSessionCoordinator == nil ? .unavailable : .signedOut
        ) else { return }
        guard let coordinator = authSessionCoordinator else { return }
        do {
            try await coordinator.signOut()
            authUIState = .signedOut
        } catch {
            authUIState = .failed("サインアウトを完了できませんでした")
        }
    }

    /// Remote shelf/history/conflict state is scoped to the authenticated
    /// AccountID. Signing out must not leave the previous scope visible or
    /// make a later account switch look like an implicit adoption.
    private func clearAccountScopedSnapshotUI() {
        invalidateSnapshotSyncV2AccountOperations()
        snapshotSyncRemoteCatalogItems = []
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
