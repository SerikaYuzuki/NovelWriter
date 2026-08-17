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
            authSession = session
            authUIState = authState
            return true
        }

        // Retire in-flight completions before waiting for the document gate.
        // The gate still owns the durable checkpoint and auth replacement, but
        // a suspended open/download must fail its stale-session check rather
        // than hold the transition behind an external await.
        invalidateSnapshotSyncV2AccountOperations()
        if isDocumentTransitionInProgress {
            // A shared remote/adoption callback can run while the gate is
            // already held. Never re-enter it; queue the same transition for
            // the first safe turn after the current operation releases it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                while isDocumentTransitionInProgress {
                    await Task.yield()
                }
                _ = await transitionFuminiwaSession(to: session, authState: authState)
            }
            return true
        }

        return await documentOperationGate.perform { [weak self] in
            guard let self,
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
                let binding = SyncV2AccountScopeBinding(
                    accountID: oldSession.accountID,
                    accountFence: oldSession.accountFence,
                    serverInstanceID: oldSession.serverInstanceID.uuidString.lowercased(),
                    protocolEpoch: Int64(oldSession.syncProtocolEpoch)
                )
                let parked = try? await application.parkAccountScope(workID: oldWorkID, binding: binding)
                if parked != nil {
                    if !checkpointed {
                        checkpointed = await saveNow()
                    }
                } else if !checkpointed {
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
    }

    /// Credential-state lookup is advisory.  It may fail offline without
    /// blocking the local SQLite workbench.
    func restoreFuminiwaSession() async {
        guard let coordinator = authSessionCoordinator else {
            authUIState = .unavailable
            return
        }
        do {
            if let orchestrator = appleAuthenticationOrchestrator {
                switch try await orchestrator.checkCredentialState() {
                case .revoked?, .notFound?, .transferred?:
                    _ = await transitionFuminiwaSession(to: nil, authState: .signedOut)
                    return
                default:
                    break
                }
            }
            let session = try await coordinator.currentSession()
            _ = await transitionFuminiwaSession(
                to: session,
                authState: session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
            )
        } catch {
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
        do {
            // The orchestrator exchanges the one-use Apple credential with the
            // auth server. The Apple token is never passed to Snapshot Sync.
            let session = try await orchestrator.signIn()
            guard await transitionFuminiwaSession(
                to: session,
                authState: .signedIn(accountID: session.accountID)
            ) else { return }
            await resumeSnapshotSyncV2()
            await refreshSnapshotLibrary()
            await refreshSnapshotRemoteCatalog()
        } catch is CancellationError {
            authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        } catch {
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
