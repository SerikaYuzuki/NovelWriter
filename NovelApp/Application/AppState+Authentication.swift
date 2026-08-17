import Foundation

extension AppState {
    var isSignedInToFuminiwa: Bool {
        if case .signedIn = authUIState {
            return true
        }
        return false
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
                    authSession = nil
                    authUIState = .signedOut
                    clearAccountScopedSnapshotUI()
                    return
                default:
                    break
                }
            }
            let session = try await coordinator.currentSession()
            authSession = session
            authUIState = session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        } catch {
            authSession = nil
            authUIState = .failed("サインイン状態を復元できませんでした")
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
            if let previous = authSession, previous.accountID != session.accountID {
                // A fence/account switch parks the old scope. Nothing from the
                // previous account is adopted into the new shelf implicitly.
                clearAccountScopedSnapshotUI()
            }
            authSession = session
            authUIState = .signedIn(accountID: session.accountID)
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
            authSession = nil
            authUIState = .unavailable
            clearAccountScopedSnapshotUI()
            return
        }
        do {
            try await coordinator.signOut()
            authSession = nil
            authUIState = .signedOut
            clearAccountScopedSnapshotUI()
        } catch {
            authUIState = .failed("サインアウトを完了できませんでした")
        }
    }

    /// Remote shelf/history/conflict state is scoped to the authenticated
    /// AccountID. Signing out must not leave the previous scope visible or
    /// make a later account switch look like an implicit adoption.
    private func clearAccountScopedSnapshotUI() {
        snapshotSyncAutoAdoptionTask?.cancel()
        snapshotSyncAutoAdoptionTask = nil
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
