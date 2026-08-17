import Foundation
import NovelAuth

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
    func transitionFuminiwaSession(
        to session: FuminiwaSession?,
        authState: AuthUIState
    ) {
        let scopeChanged = authSession?.accountID != session?.accountID
            || authSession?.accountFence != session?.accountFence
        if scopeChanged {
            clearAccountScopedSnapshotUI()
        }
        authSession = session
        authUIState = authState
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
                    transitionFuminiwaSession(to: nil, authState: .signedOut)
                    return
                default:
                    break
                }
            }
            let session = try await coordinator.currentSession()
            transitionFuminiwaSession(
                to: session,
                authState: session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
            )
        } catch {
            transitionFuminiwaSession(
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
        authUIState = .signingIn
        do {
            // The orchestrator exchanges the one-use Apple credential with the
            // auth server. The Apple token is never passed to Snapshot Sync.
            let session = try await orchestrator.signIn()
            transitionFuminiwaSession(
                to: session,
                authState: .signedIn(accountID: session.accountID)
            )
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
        guard let coordinator = authSessionCoordinator else {
            clearAccountScopedSnapshotUI()
            authSession = nil
            authUIState = .unavailable
            return
        }
        // Invalidate old-account downloads and adoption before the revocation
        // request can suspend. A failed sign-out may resume the same scope,
        // but no response started before this user action may reach the UI.
        invalidateSnapshotSyncV2AccountOperations()
        do {
            try await coordinator.signOut()
            transitionFuminiwaSession(to: nil, authState: .signedOut)
        } catch {
            authUIState = .failed("サインアウトを完了できませんでした")
            await resumeSnapshotSyncV2()
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
