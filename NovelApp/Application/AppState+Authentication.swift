import Foundation

extension AppState {
    var isSignedInToFuminiwa: Bool {
        if case .signedIn = authUIState {
            return true
        }
        return false
    }

    /// Restores only the opaque FUMINIWA session from the device vault. A
    /// failed restore never blocks local startup or offline editing.
    func restoreFuminiwaSession() async {
        guard let coordinator = authSessionCoordinator else {
            authUIState = .unavailable
            return
        }
        do {
            let session = try await coordinator.currentSession()
            authSession = session
            authUIState = session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        } catch {
            authSession = nil
            authUIState = .failed("サインイン状態を復元できませんでした")
        }
    }

    /// Performs the complete native Apple flow. The Apple adapter owns the
    /// UI presentation; this AppState method only coordinates the challenge,
    /// one-use credential handoff, and FUMINIWA session persistence.
    func signInWithApple() async {
        guard let coordinator = authSessionCoordinator,
              let apple = appleSignInCoordinator else {
            authUIState = .unavailable
            return
        }
        guard authUIState != .signingIn else { return }
        authUIState = .signingIn
        do {
            let challenge = try await coordinator.createAppleChallenge()
            let authorization = try await apple.authorize(using: challenge)
            let session = try await coordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: authorization.authorizationCode,
                identityToken: authorization.identityToken
            )
            authSession = session
            authUIState = .signedIn(accountID: session.accountID)
            await resumePendingSnapshotSync()
            // A user may have signed in from the empty startup shelf. Refresh
            // the snapshot catalog immediately so remote-only works become
            // discoverable without restarting the app.
            if usesSnapshotSyncRuntime,
               case let .documentSelection(context) = startupState,
               context.presentation == .cloudLibrary {
                await refreshSnapshotLibrary()
            }
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
            return
        }
        do {
            try await coordinator.signOut()
        } catch {
            // Local work and the Keychain session remain safe even when the
            // server is offline. The vault is deliberately not cleared on a
            // failed revoke so the next retry can finish the server session.
            authUIState = .failed("サインアウトを完了できませんでした")
            return
        }
        authSession = nil
        authUIState = .signedOut
    }
}
