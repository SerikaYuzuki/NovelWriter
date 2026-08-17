import Foundation
import NovelAuth
import NovelAuthApple
import NovelSyncV2Application

extension AppState {
    @discardableResult
    private func endRemoteSuspension(
        application: SyncV2Application?,
        token: SyncV2AccountTransitionRemoteSuspensionToken?,
        resume: Bool
    ) async -> Bool {
        guard let application, let token else { return true }
        return await application.endAccountTransitionRemoteSuspension(token, resume: resume)
    }

    private func makeAuthOperationOwner() -> UUID {
        UUID()
    }

    private func claimAuthOperation(_ owner: UUID) {
        authOperationOwner = owner
        invalidateSnapshotSyncV2AccountOperations()
    }

    private func beginAuthOperation() -> UUID {
        let owner = makeAuthOperationOwner()
        claimAuthOperation(owner)
        return owner
    }

    private func ownsAuthOperation(_ owner: UUID) -> Bool {
        authOperationOwner == owner
    }

    private func beginInteractiveAuthOperation() -> UUID {
        let token = UUID()
        interactiveAuthOperationOwners.insert(token)
        interactiveAuthOperationCount = interactiveAuthOperationOwners.count
        return token
    }

    private func releaseInteractiveAuthOperation(_ token: UUID) {
        guard interactiveAuthOperationOwners.remove(token) != nil else { return }
        interactiveAuthOperationCount = interactiveAuthOperationOwners.count
    }

    private func accountBinding(
        for session: FuminiwaSession?
    ) -> SyncV2AccountScopeBinding? {
        session.map {
            SyncV2AccountScopeBinding(
                accountID: $0.accountID,
                accountFence: $0.accountFence,
                serverInstanceID: $0.serverInstanceID.uuidString.lowercased(),
                protocolEpoch: Int64($0.syncProtocolEpoch)
            )
        }
    }

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
        authState: AuthUIState,
        owner: UUID? = nil,
        suspensionToken suppliedSuspensionToken: SyncV2AccountTransitionRemoteSuspensionToken? = nil,
        releaseRemoteSuspension: Bool = true,
        resumeRemoteAfterTransition: Bool = true
    ) async -> Bool {
        let operationOwner = owner ?? beginAuthOperation()
        guard ownsAuthOperation(operationOwner) else { return false }
        // An epoch-mismatched vault session is not a usable destination. It
        // is deliberately normalized to sign-out so cold launch can park all
        // database lanes instead of leaving an old bound Work unprojectable.
        let acceptedSession = session?.syncProtocolEpoch == 2 ? session : nil
        let acceptedAuthState: AuthUIState = if session != nil && acceptedSession == nil {
            .unavailable
        } else {
            authState
        }
        let oldBinding = accountBinding(for: authSession)
        let newBinding = accountBinding(for: acceptedSession)
        let scopeChanged = oldBinding != newBinding
        let needsDurableReconciliation = snapshotSyncV2Application != nil &&
            (authSession == nil || acceptedSession == nil || scopeChanged)
        guard scopeChanged || needsDurableReconciliation else {
            authSession = acceptedSession
            authUIState = acceptedAuthState
            return true
        }

        // Retire in-flight completions before waiting for the document gate.
        // The gate still owns the durable checkpoint and auth replacement, but
        // a suspended open/download must fail its stale-session check rather
        // than hold the transition behind an external await.
        invalidateSnapshotSyncV2AccountOperations()
        let requestGeneration = snapshotSyncV2AccountScopeGeneration
        let transitionApplication = snapshotSyncV2Application
        let remoteSuspensionToken: SyncV2AccountTransitionRemoteSuspensionToken? = if let suppliedSuspensionToken {
            suppliedSuspensionToken
        } else if let transitionApplication {
            await transitionApplication.beginAccountTransitionRemoteSuspension()
        } else {
            nil
        }
        let transitioned = await documentOperationGate.perform { [weak self] in
            guard let self,
                  ownsAuthOperation(operationOwner),
                  snapshotSyncV2AccountScopeGeneration == requestGeneration,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }

            let oldWorkID = currentSnapshotSyncV2WorkID
            // During cold launch the vault may already contain the attested
            // destination while the database still carries an old binding.
            // Do not rewrite the existing Work before its binding has been
            // reconciled; the durable transition below is the first write.
            let shouldCheckpoint = acceptedSession == nil ||
                authSession != nil ||
                (oldWorkID != nil && saveState != .saved)
            var checkpointed = !shouldCheckpoint || saveState == .saved || oldWorkID == nil
            if !checkpointed {
                checkpointed = await saveNow()
            }

            guard ownsAuthOperation(operationOwner),
                  checkpointed,
                  let application = snapshotSyncV2Application else {
                if snapshotSyncV2Application == nil, checkpointed {
                    // Auth can remain usable in a local-only composition.
                } else {
                    return false
                }
                clearAccountScopedSnapshotUI()
                authSession = acceptedSession
                authUIState = acceptedAuthState
                return true
            }

            do {
                guard let remoteSuspensionToken else {
                    return false
                }
                try await application.transitionAccountScopes(
                    from: oldBinding,
                    to: newBinding,
                    suspensionToken: remoteSuspensionToken
                )
            } catch {
                // Parking/quarantining is part of the auth transition. A
                // failure leaves the old editor, shelf, and auth state intact.
                return false
            }
            guard ownsAuthOperation(operationOwner) else { return false }
            clearAccountScopedSnapshotUI()
            documentSessionToken = AppDocumentSessionToken(
                generation: documentSessionToken.generation &+ 1,
                documentID: document.id,
                workID: currentSnapshotSyncV2WorkID ?? documentSessionToken.workID
            )
            if let application = snapshotSyncV2Application, let workID = currentSnapshotSyncV2WorkID {
                let newSession = await application.beginSession(workID: workID)
                guard ownsAuthOperation(operationOwner) else { return false }
                snapshotSyncV2Session = newSession
            }
            guard ownsAuthOperation(operationOwner) else { return false }
            authSession = acceptedSession
            authUIState = acceptedAuthState
            return true
        }
        if releaseRemoteSuspension, let transitionApplication, let remoteSuspensionToken {
            _ = await transitionApplication.endAccountTransitionRemoteSuspension(
                remoteSuspensionToken,
                resume: !transitioned
            )
        }
        guard transitioned, ownsAuthOperation(operationOwner) else { return false }
        // Reproject local parked work immediately. This is deliberately after
        // the gate so the shelf cannot observe a half-completed transition.
        await refreshSnapshotLibrary()
        guard ownsAuthOperation(operationOwner) else { return false }
        if resumeRemoteAfterTransition {
            await resumeSnapshotSyncV2()
        }
        return ownsAuthOperation(operationOwner)
    }

    /// Credential-state lookup is advisory.  It may fail offline without
    /// blocking the local SQLite workbench.
    func restoreFuminiwaSession() async {
        let owner = makeAuthOperationOwner()
        await authOperationGate.perform { [weak self] in
            guard let self else { return }
            claimAuthOperation(owner)
            await restoreFuminiwaSessionOwned(owner: owner)
        }
    }

    private func restoreFuminiwaSessionOwned(owner: UUID) async {
        let transitionApplication = snapshotSyncV2Application
        let suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken? = if let transitionApplication {
            await transitionApplication.beginAccountTransitionRemoteSuspension()
        } else {
            nil
        }
        guard let coordinator = authSessionCoordinator else {
            _ = await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: true
            )
            guard ownsAuthOperation(owner) else { return }
            authUIState = .unavailable
            return
        }
        do {
            if await reconcileCredentialStateBeforeRestore(
                owner: owner,
                application: transitionApplication,
                suspensionToken: suspensionToken
            ) {
                return
            }
            let session = try await coordinator.currentSession()
            guard ownsAuthOperation(owner) else {
                _ = await endRemoteSuspension(
                    application: transitionApplication,
                    token: suspensionToken,
                    resume: false
                )
                return
            }
            if await reconcileUnsupportedSession(
                session: session,
                coordinator: coordinator,
                owner: owner,
                application: transitionApplication,
                suspensionToken: suspensionToken
            ) {
                return
            }
            let transitioned = await transitionFuminiwaSession(
                to: session,
                authState: session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut,
                owner: owner,
                suspensionToken: suspensionToken,
                releaseRemoteSuspension: false,
                resumeRemoteAfterTransition: false
            )
            let released = await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: !transitioned
            )
            guard transitioned, released, ownsAuthOperation(owner) else { return }
            await resumeSnapshotSyncV2()
        } catch {
            guard ownsAuthOperation(owner) else {
                _ = await endRemoteSuspension(
                    application: transitionApplication,
                    token: suspensionToken,
                    resume: false
                )
                return
            }
            let transitioned = await transitionFuminiwaSession(
                to: nil,
                authState: .failed("サインイン状態を復元できませんでした"),
                owner: owner,
                suspensionToken: suspensionToken,
                releaseRemoteSuspension: false,
                resumeRemoteAfterTransition: false
            )
            _ = await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: !transitioned
            )
        }
    }

    private func reconcileUnsupportedSession(
        session: FuminiwaSession?,
        coordinator: AuthSessionCoordinator,
        owner: UUID,
        application: SyncV2Application?,
        suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken?
    ) async -> Bool {
        guard let session, session.syncProtocolEpoch != 2 else { return false }
        // The local vault can outlive the client protocol. Reconcile the
        // database to a parked projection before removing the unusable
        // credential, without touching a later auth owner.
        let transitioned = await transitionFuminiwaSession(
            to: session,
            authState: .unavailable,
            owner: owner,
            suspensionToken: suspensionToken,
            releaseRemoteSuspension: false,
            resumeRemoteAfterTransition: false
        )
        guard transitioned else {
            _ = await endRemoteSuspension(
                application: application,
                token: suspensionToken,
                resume: true
            )
            return true
        }
        do {
            try await coordinator.signOut()
        } catch {
            guard ownsAuthOperation(owner) else {
                _ = await endRemoteSuspension(
                    application: application,
                    token: suspensionToken,
                    resume: false
                )
                return true
            }
            authUIState = .unavailable
        }
        _ = await endRemoteSuspension(
            application: application,
            token: suspensionToken,
            resume: false
        )
        return true
    }

    private func reconcileCredentialStateBeforeRestore(
        owner: UUID,
        application: SyncV2Application?,
        suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken?
    ) async -> Bool {
        guard let orchestrator = appleAuthenticationOrchestrator else { return false }
        do {
            let credentialState = try await orchestrator.checkCredentialState()
            guard ownsAuthOperation(owner) else {
                _ = await endRemoteSuspension(
                    application: application,
                    token: suspensionToken,
                    resume: false
                )
                return true
            }
            switch credentialState {
            case .revoked?, .notFound?, .transferred?:
                break
            default:
                return false
            }
            let transitioned = await transitionFuminiwaSession(
                to: nil,
                authState: .signedOut,
                owner: owner,
                suspensionToken: suspensionToken,
                releaseRemoteSuspension: false,
                resumeRemoteAfterTransition: false
            )
            _ = await endRemoteSuspension(
                application: application,
                token: suspensionToken,
                resume: !transitioned
            )
            return true
        } catch {
            // Apple credential state is advisory. Offline/transient lookup
            // failure must not park a still-valid local scope; the attested
            // session lookup below remains authoritative.
            guard ownsAuthOperation(owner) else {
                _ = await endRemoteSuspension(
                    application: application,
                    token: suspensionToken,
                    resume: false
                )
                return true
            }
            return false
        }
    }

    func signInWithApple() async {
        guard let orchestrator = appleAuthenticationOrchestrator else {
            authUIState = .unavailable
            return
        }
        // A sign-in requested while sign-out is waiting for remote revoke is
        // queued by the auth gate without blocking local work. Keep one
        // request owner from the tap through the serialized exchange so a
        // double tap cannot enqueue a second Apple flow.
        guard !pendingSignInRequest else { return }
        pendingSignInRequest = true
        defer { pendingSignInRequest = false }
        let owner = makeAuthOperationOwner()
        await authOperationGate.perform { [weak self] in
            guard let self else { return }
            guard authUIState != .signingIn else { return }
            claimAuthOperation(owner)
            let transitionBlocker = beginInteractiveAuthOperation()
            defer { releaseInteractiveAuthOperation(transitionBlocker) }
            await signInWithAppleOwned(
                orchestrator: orchestrator,
                owner: owner,
                transitionBlocker: transitionBlocker
            )
        }
    }

    private func signInWithAppleOwned(
        orchestrator: AppleAuthenticationOrchestrator,
        owner: UUID,
        transitionBlocker: UUID
    ) async {
        let previousSession = authSession
        let transitionApplication = snapshotSyncV2Application
        let suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken? = if let transitionApplication {
            await transitionApplication.beginAccountTransitionRemoteSuspension()
        } else {
            nil
        }
        // The Apple exchange persists the new vault session before returning.
        // Retire the old binding first so its dirty editor can never be
        // checkpointed against the new account's scope.
        let parked = await transitionFuminiwaSession(
            to: nil,
            authState: .signingIn,
            owner: owner,
            suspensionToken: suspensionToken,
            releaseRemoteSuspension: false,
            resumeRemoteAfterTransition: false
        )
        guard parked else {
            await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: true
            )
            return
        }
        // The old scope is durably parked. Keep auth ownership and the vault
        // exchange serialized, but let local replacement operations continue
        // while Apple/network is waiting.
        releaseInteractiveAuthOperation(transitionBlocker)
        authUIState = .signingIn
        do {
            // The orchestrator exchanges the one-use Apple credential with the
            // auth server. The Apple token is never passed to Snapshot Sync.
            let session = try await orchestrator.signIn()
            guard ownsAuthOperation(owner) else {
                await endRemoteSuspension(
                    application: transitionApplication,
                    token: suspensionToken,
                    resume: false
                )
                return
            }
            let rebound = await transitionFuminiwaSession(
                to: session,
                authState: .signedIn(accountID: session.accountID),
                owner: owner,
                suspensionToken: suspensionToken,
                releaseRemoteSuspension: false,
                resumeRemoteAfterTransition: false
            )
            guard rebound else {
                _ = await recoverAfterAppleSignInFailure(
                    previousSession: previousSession,
                    owner: owner,
                    application: transitionApplication,
                    suspensionToken: suspensionToken
                )
                return
            }
            await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: false
            )
            guard ownsAuthOperation(owner) else { return }
            await resumeSnapshotSyncV2()
            await refreshSnapshotLibrary()
            await refreshSnapshotRemoteCatalog()
        } catch is CancellationError {
            _ = await recoverAfterAppleSignInFailure(
                previousSession: previousSession,
                owner: owner,
                application: transitionApplication,
                suspensionToken: suspensionToken
            )
        } catch {
            _ = await recoverAfterAppleSignInFailure(
                previousSession: previousSession,
                owner: owner,
                application: transitionApplication,
                suspensionToken: suspensionToken
            )
        }
    }

    /// Apple authorization may fail after its server exchange has already
    /// committed the vault (for example, while saving the provider handle).
    /// Reconcile against that exact vault owner; otherwise restore the session
    /// that was parked before the exchange. The old local scope is never left
    /// durably parked merely because the provider callback failed.
    private func recoverAfterAppleSignInFailure(
        previousSession: FuminiwaSession?,
        owner: UUID,
        application: SyncV2Application?,
        suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken?
    ) async -> Bool {
        guard ownsAuthOperation(owner) else {
            _ = await endRemoteSuspension(
                application: application,
                token: suspensionToken,
                resume: false
            )
            return false
        }
        let destination: FuminiwaSession?
        if let coordinator = authSessionCoordinator {
            do {
                destination = try await coordinator.currentSession() ?? previousSession
            } catch {
                destination = previousSession
            }
        } else {
            destination = previousSession
        }
        guard let destination else {
            authSession = nil
            authUIState = .signedOut
            _ = await endRemoteSuspension(
                application: application,
                token: suspensionToken,
                resume: false
            )
            return false
        }
        let recovered = await transitionFuminiwaSession(
            to: destination,
            authState: .signedIn(accountID: destination.accountID),
            owner: owner,
            suspensionToken: suspensionToken,
            releaseRemoteSuspension: false,
            resumeRemoteAfterTransition: false
        )
        let released = await endRemoteSuspension(
            application: application,
            token: suspensionToken,
            resume: !recovered
        )
        guard recovered, released, ownsAuthOperation(owner) else { return false }
        authUIState = .signedIn(accountID: destination.accountID)
        await resumeSnapshotSyncV2()
        await refreshSnapshotLibrary()
        return true
    }

    func signOutFromFuminiwa() async {
        let owner = makeAuthOperationOwner()
        await authOperationGate.perform { [weak self] in
            guard let self else { return }
            claimAuthOperation(owner)
            // Do not hold the document-transition blocker while waiting for
            // this auth gate. A prior Apple exchange or revoke may be
            // indefinitely suspended; local new/open/edit/save/import/export
            // must remain available until this operation actually owns the
            // short durable park transition.
            let transitionBlocker = beginInteractiveAuthOperation()
            await signOutFromFuminiwaOwned(
                owner: owner,
                transitionBlocker: transitionBlocker
            )
        }
    }

    private func signOutFromFuminiwaOwned(
        owner: UUID,
        transitionBlocker: UUID
    ) async {
        let transitionApplication = snapshotSyncV2Application
        let suspensionToken: SyncV2AccountTransitionRemoteSuspensionToken? = if let transitionApplication {
            await transitionApplication.beginAccountTransitionRemoteSuspension()
        } else {
            nil
        }
        let parked = await transitionFuminiwaSession(
            to: nil,
            authState: authSessionCoordinator == nil ? .unavailable : .signedOut,
            owner: owner,
            suspensionToken: suspensionToken,
            releaseRemoteSuspension: false,
            resumeRemoteAfterTransition: false
        )
        guard parked else {
            releaseInteractiveAuthOperation(transitionBlocker)
            await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: true
            )
            return
        }
        // Once the old durable scope is parked, local open/new/import/export
        // may continue while the server-side revoke is offline. The auth
        // gate itself remains occupied so a later auth request cannot race
        // the outstanding vault/revoke operation.
        releaseInteractiveAuthOperation(transitionBlocker)
        guard let coordinator = authSessionCoordinator else {
            await endRemoteSuspension(
                application: transitionApplication,
                token: suspensionToken,
                resume: false
            )
            return
        }
        do {
            try await coordinator.signOut()
            if ownsAuthOperation(owner) {
                authUIState = .signedOut
            }
        } catch {
            if ownsAuthOperation(owner) {
                authUIState = .failed("サインアウトを完了できませんでした")
            }
        }
        await endRemoteSuspension(
            application: transitionApplication,
            token: suspensionToken,
            resume: false
        )
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
