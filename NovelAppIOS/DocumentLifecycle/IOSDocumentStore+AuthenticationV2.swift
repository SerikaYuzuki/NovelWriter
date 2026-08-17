import Foundation
import NovelAuth
import NovelSyncV2Application

private enum IOSDocumentStoreAuthenticationError: Error {
    case unavailable
}

private struct IOSAccountTransitionLease {
    let owner: UUID
    let ownsRequest: Bool
}

extension IOSDocumentStore {
    /// Opens the short auth-request window and invalidates every iOS-owned
    /// account-scoped task before an exchange can suspend.  The shared
    /// application lease is acquired before the first IME/dirty checkpoint.
    /// This boundary is deliberately the common entry point for restore,
    /// sign-in, signout, and direct account transitions.
    @discardableResult
    func beginAccountTransitionRequest() async -> UUID? {
        guard !syncV2AccountTransitionRequested,
              syncV2AccountTransitionRequestOwner == nil,
              !syncV2AccountTransitionInProgress else { return nil }
        let owner = UUID()
        syncV2AccountTransitionRequested = true
        syncV2AccountTransitionRequestOwner = owner
        cancelSnapshotSyncV2BackgroundOperations()
        invalidateSnapshotSyncV2AccountOperations()
        if let application = snapshotSyncV2Application {
            let token = await application.beginAccountTransitionRemoteSuspension()
            guard syncV2AccountTransitionRequestOwner == owner,
                  syncV2AccountTransitionRequested else {
                _ = await application.endAccountTransitionRemoteSuspension(
                    token,
                    resume: false
                )
                return nil
            }
            syncV2RemoteSuspensionToken = token
        }
        return owner
    }

    private func acquireAccountTransitionRequest(
        expectedOwner: UUID? = nil
    ) async -> IOSAccountTransitionLease? {
        if syncV2AccountTransitionRequested {
            guard !syncV2AccountTransitionInProgress,
                  let owner = syncV2AccountTransitionRequestOwner,
                  expectedOwner == owner else { return nil }
            return IOSAccountTransitionLease(owner: owner, ownsRequest: false)
        }
        guard expectedOwner == nil,
              let owner = await beginAccountTransitionRequest() else { return nil }
        return IOSAccountTransitionLease(owner: owner, ownsRequest: true)
    }

    private func releaseAccountTransitionRequest(
        owner: UUID,
        resume: Bool
    ) async {
        guard syncV2AccountTransitionRequestOwner == owner else { return }
        let token = syncV2RemoteSuspensionToken
        if let token, let application = snapshotSyncV2Application {
            _ = await application.endAccountTransitionRemoteSuspension(
                token,
                resume: resume
            )
        }
        guard syncV2AccountTransitionRequestOwner == owner else { return }
        syncV2RemoteSuspensionToken = nil
        syncV2AccountTransitionRequestOwner = nil
        syncV2AccountTransitionRequested = false
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
        return try await appleAuthenticationOrchestrator.signIn()
    }

    private func snapshotSyncV2Binding(
        for session: FuminiwaSession
    ) -> SyncV2AccountScopeBinding {
        let serverInstanceID: String
        #if FUMINIWA_TEST_COMPOSITION
        serverInstanceID = testServerInstanceIDOverride
            ?? session.serverInstanceID.uuidString.lowercased()
        #else
        serverInstanceID = session.serverInstanceID.uuidString.lowercased()
        #endif
        return SyncV2AccountScopeBinding(
            accountID: session.accountID,
            accountFence: session.accountFence,
            serverInstanceID: serverInstanceID,
            protocolEpoch: Int64(session.syncProtocolEpoch)
        )
    }

    /// An old-epoch vault value is never a usable destination binding. Reuse
    /// the cold-launch reconciliation path to park every persisted active
    /// lane, then expose only the local shelf. The false result is retained
    /// for callers that need to treat the auth restore as a typed failure.
    private func failClosedForUnsupportedSession(
        expectedOwner: UUID? = nil
    ) async -> Bool {
        guard let lease = await acquireAccountTransitionRequest(
            expectedOwner: expectedOwner
        ) else { return false }

        guard let application = snapshotSyncV2Application else {
            retainLocalOnlyIOSLibraryProjection()
            authSession = nil
            authUIState = .failed("このバージョンの同期セッションには対応していません")
            if lease.ownsRequest {
                await releaseAccountTransitionRequest(
                    owner: lease.owner,
                    resume: false
                )
            }
            return false
        }
        guard let suspensionToken = syncV2RemoteSuspensionToken else {
            if lease.ownsRequest {
                await releaseAccountTransitionRequest(
                    owner: lease.owner,
                    resume: true
                )
            }
            return false
        }

        let transitioned = await documentOperationGate.perform { [weak self] in
            guard let self,
                  !isDocumentTransitionInProgress else { return false }
            syncV2AccountTransitionInProgress = true
            defer { syncV2AccountTransitionInProgress = false }
            guard await performDocumentTransition({}) else { return false }
            do {
                // The persisted inventory, not the invalid vault value, is
                // the source of truth for this safe retirement.
                try await application.transitionAccountScopes(
                    from: nil,
                    to: nil,
                    suspensionToken: suspensionToken
                )
            } catch {
                return false
            }
            dismissExport()
            clearAccountScopedSnapshotUIForIOS()
            syncV2ParkedAccountID = authSession?.accountID
            authSession = nil
            authUIState = .failed("このバージョンの同期セッションには対応していません")
            return true
        }
        guard transitioned else {
            if lease.ownsRequest {
                await releaseAccountTransitionRequest(
                    owner: lease.owner,
                    resume: true
                )
            }
            return false
        }
        _ = try? await reloadLibraryItems()
        if lease.ownsRequest {
            await releaseAccountTransitionRequest(
                owner: lease.owner,
                resume: false
            )
        }
        return false
    }

    /// Performs the durable account boundary before publishing the replacement
    /// auth session. The application owns the persisted binding inventory and
    /// one SQLite transaction, including cold-launch reconciliation when the
    /// in-memory session is nil but the vault/database already contain lanes.
    @discardableResult
    // swiftlint:disable:next function_body_length
    func transitionFuminiwaSession(
        to session: FuminiwaSession?,
        authState: IOSAuthUIState,
        requestOwner: UUID? = nil
    ) async -> Bool {
        guard session == nil || session?.syncProtocolEpoch == 2 else {
            // A vault entry from an older protocol epoch is not an account
            // binding. Retire persisted lanes without publishing it to UI or
            // the Snapshot Sync runtime.
            return await failClosedForUnsupportedSession(
                expectedOwner: requestOwner
            )
        }
        let oldSession = authSession
        let oldScope = snapshotSyncV2AccountScope
        let newScope = session.map {
            let serverInstanceID: String
            #if FUMINIWA_TEST_COMPOSITION
            serverInstanceID = testServerInstanceIDOverride
                ?? $0.serverInstanceID.uuidString.lowercased()
            #else
            serverInstanceID = $0.serverInstanceID.uuidString.lowercased()
            #endif
            return IOSSnapshotSyncV2AccountScope(
                accountID: $0.accountID,
                accountFence: $0.accountFence,
                serverInstanceID: serverInstanceID,
                protocolEpoch: Int64($0.syncProtocolEpoch)
            )
        } ?? IOSSnapshotSyncV2AccountScope(
            accountID: nil,
            accountFence: nil,
            serverInstanceID: nil,
            protocolEpoch: nil
        )
        let changed = oldScope != newScope
        let needsDurableReconciliation = snapshotSyncV2Application != nil &&
            (oldSession == nil || session == nil || changed)

        if !changed, !needsDurableReconciliation {
            if syncV2AccountTransitionRequested {
                guard let requestOwner,
                      syncV2AccountTransitionRequestOwner == requestOwner else {
                    return false
                }
            }
            if oldSession == nil, session == nil {
                invalidateSnapshotSyncV2AccountOperations()
                clearAccountScopedSnapshotUIForIOS()
                retainLocalOnlyIOSLibraryProjection()
            }
            authSession = session
            authUIState = authState
            return true
        }

        guard let lease = await acquireAccountTransitionRequest(
            expectedOwner: requestOwner
        ) else { return false }

        guard let application = snapshotSyncV2Application else {
            // A store which has not configured v2 has no account-scoped lane.
            // It is safe to publish the session, while a configured runtime
            // must complete the durable boundary below.
            if session == nil {
                clearAccountScopedSnapshotUIForIOS()
                retainLocalOnlyIOSLibraryProjection()
            }
            authSession = session
            authUIState = authState
            if lease.ownsRequest {
                await releaseAccountTransitionRequest(
                    owner: lease.owner,
                    resume: false
                )
            }
            return true
        }
        guard let suspensionToken = syncV2RemoteSuspensionToken else {
            if lease.ownsRequest {
                await releaseAccountTransitionRequest(
                    owner: lease.owner,
                    resume: true
                )
            }
            return false
        }

        let oldBinding = oldSession.map(snapshotSyncV2Binding(for:))
        let newBinding = session.map(snapshotSyncV2Binding(for:))

        let transitioned = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            guard !isDocumentTransitionInProgress else { return false }
            syncV2AccountTransitionInProgress = true
            defer { syncV2AccountTransitionInProgress = false }

            // This boundary confirms IME state and flushes the active editor
            // to SQLite before any old account lane is retired.
            guard await performDocumentTransition({}) else { return false }

            do {
                try await application.transitionAccountScopes(
                    from: oldBinding,
                    to: newBinding,
                    suspensionToken: suspensionToken
                )
            } catch {
                // Keep the old auth/session and editor intact when the
                // database-wide exact transition cannot commit.
                return false
            }

            // Clear only account-scoped UI. Parked local works remain in the
            // SQLite projection and keep their WorkID as the reopen anchor.
            dismissExport()
            clearAccountScopedSnapshotUIForIOS()
            syncV2ParkedAccountID = session == nil ? oldSession?.accountID : nil
            authSession = session
            authUIState = authState
            return true
        }
        guard transitioned else {
            if lease.ownsRequest {
                await releaseAccountTransitionRequest(
                    owner: lease.owner,
                    resume: true
                )
            }
            return false
        }

        _ = try? await reloadLibraryItems()
        if lease.ownsRequest {
            await releaseAccountTransitionRequest(
                owner: lease.owner,
                resume: false
            )
            await resumeSnapshotSyncV2AfterAuthTransition()
        }
        return true
    }

    /// The caller owns the short request window around an auth exchange.  Do
    /// not start account-scoped remote work until that owner has released the
    /// window; otherwise the worker task would be created successfully and
    /// then immediately rejected by the transition gate.
    private func resumeSnapshotSyncV2AfterAuthTransition() async {
        guard !isSyncV2AccountTransitionActive,
              authSession != nil,
              let application = snapshotSyncV2Application else { return }
        let expectedAccountScope = snapshotSyncV2AccountScope
        // Ended suspension leases never implicitly wake the replacement
        // scope. Resume its durable pending lane explicitly after the new
        // session has been published and the old token has been released.
        try? await application.resumePending()
        await resumeSnapshotSyncV2()
        guard !isSyncV2AccountTransitionActive,
              snapshotSyncV2AccountScope == expectedAccountScope else { return }
        _ = await refreshRemoteCatalog(reset: true)
    }

    /// Replays a parked revoke without participating in the local account
    /// transition. A failure remains in the vault for the next launch.
    func resumePendingAuthRevoke() {
        guard authRevokeRetryTask == nil,
              let coordinator = authSessionCoordinator,
              let vault = authSessionVault else { return }
        authRevokeRetryTask = Task { @MainActor [weak self] in
            defer { self?.authRevokeRetryTask = nil }
            guard let self else { return }
            do {
                guard try await vault.loadPendingRevoke() != nil else { return }
                try await coordinator.signOut()
                if authSession == nil {
                    authUIState = .signedOut
                }
            } catch {
                // Keep the pending revoke in the vault. Local editing remains
                // available and a future launch/foreground event retries it.
                if authSession == nil {
                    authUIState = .failed("サインアウトの同期は保留中です")
                }
            }
        }
    }

    private func restoreSessionAfterAppleFailure(
        fallback: FuminiwaSession?,
        requestOwner: UUID
    ) async -> Bool {
        let vaultSession = try? await authSessionCoordinator?.currentSession()
        let restoredSession = vaultSession ?? fallback
        guard let restoredSession else { return false }
        return await transitionFuminiwaSession(
            to: restoredSession,
            authState: .signedIn(accountID: restoredSession.accountID),
            requestOwner: requestOwner
        )
    }

    private func clearAccountScopedSnapshotUIForIOS() {
        syncV2RemoteCatalogItems = []
        syncV2RemoteCatalogCursor = nil
        syncV2RemoteCatalogError = nil
        syncV2HistoryItems = []
        syncV2HistoryCursor = nil
        syncV2HistoryWorkID = nil
        syncV2HistoryLocalAvailability = .unavailable
        syncV2HistoryOnlineAvailability = .unavailable
        syncV2HistoryOnlineFailure = nil
        snapshotSyncConflict = nil
        snapshotSyncState = nil
        snapshotSyncOutcome = .offline
    }

    private func retainLocalOnlyIOSLibraryProjection() {
        syncV2LibraryItems = syncV2LibraryItems.filter {
            $0.accountState == .unbound || $0.accountState == .parkedDifferentAccount
        }
    }

    func flushDeviceSyncForBackground(waitForRemote _: Bool) async -> Bool {
        _ = await saveNow()
        Task { await resumeSnapshotSyncV2() }
        return saveState == .saved
    }

    func captureAutomaticSnapshotForBackground() async {}

    func restoreFuminiwaSession() async {
        guard let owner = await beginAccountTransitionRequest() else { return }
        guard let coordinator = authSessionCoordinator else {
            let transitioned = await transitionFuminiwaSession(
                to: nil,
                authState: .unavailable,
                requestOwner: owner
            )
            await releaseAccountTransitionRequest(
                owner: owner,
                resume: !transitioned
            )
            return
        }
        do {
            let restoredSession = try await coordinator.currentSession()
            let state = restoredSession.map { IOSAuthUIState.signedIn(accountID: $0.accountID) }
                ?? .signedOut
            let transitioned = await transitionFuminiwaSession(
                to: restoredSession,
                authState: state,
                requestOwner: owner
            )
            // An unsupported epoch is deliberately parked by the fail-closed
            // path even though it returns false as a typed auth failure.
            let shouldResumeOldScope = restoredSession?.syncProtocolEpoch == 2
                && !transitioned
            await releaseAccountTransitionRequest(
                owner: owner,
                resume: shouldResumeOldScope
            )
            guard transitioned else { return }
            if restoredSession != nil {
                await resumeSnapshotSyncV2AfterAuthTransition()
            }
        } catch {
            let transitioned = await transitionFuminiwaSession(
                to: nil,
                authState: .failed("サインイン状態を復元できませんでした"),
                requestOwner: owner
            )
            await releaseAccountTransitionRequest(
                owner: owner,
                resume: !transitioned
            )
        }
    }

    func signInWithApple() async {
        #if !FUMINIWA_TEST_COMPOSITION
        guard appleAuthenticationOrchestrator != nil else {
            authUIState = .unavailable
            return
        }
        #else
        guard appleAuthenticationOrchestrator != nil || testAppleSignInHandler != nil else {
            authUIState = .unavailable
            return
        }
        #endif
        guard authUIState != .signingIn else { return }
        let previousAuthUIState = authUIState
        let previousSession = authSession
        guard let owner = await beginAccountTransitionRequest() else { return }
        authUIState = .signingIn
        // The Apple exchange may persist the replacement vault session before
        // it returns. Flush the current editor while the old vault binding is
        // still usable; the durable scope transaction below then retires that
        // exact binding before publishing the returned session.
        let preflighted = await documentOperationGate.perform { [weak self] in
            guard let self,
                  !isDocumentTransitionInProgress else { return false }
            syncV2AccountTransitionInProgress = true
            defer { syncV2AccountTransitionInProgress = false }
            return await performDocumentTransition {}
        }
        guard preflighted else {
            authUIState = previousAuthUIState
            await releaseAccountTransitionRequest(owner: owner, resume: true)
            return
        }
        var oldScopeParked = false
        do {
            // Retire the old binding before the Apple exchange suspends.  A
            // failure leaves this local editor on the parked shelf; a later
            // successful session rebinds it through the same durable API.
            guard await transitionFuminiwaSession(
                to: nil,
                authState: .signingIn,
                requestOwner: owner
            ) else {
                authUIState = previousAuthUIState
                await releaseAccountTransitionRequest(owner: owner, resume: true)
                _ = try? await reloadLibraryItems()
                return
            }
            oldScopeParked = true
            let session = try await exchangeAppleSession()
            guard await transitionFuminiwaSession(
                to: session,
                authState: .signedIn(accountID: session.accountID),
                requestOwner: owner
            ) else {
                authUIState = .failed("新しいAppleセッションを適用できませんでした")
                // The exchange may already have atomically committed its new
                // vault session. Re-read it and perform the exact durable
                // transition; if it did not commit, the old session remains
                // the fallback destination.
                let restored = await restoreSessionAfterAppleFailure(
                    fallback: previousSession,
                    requestOwner: owner
                )
                await releaseAccountTransitionRequest(owner: owner, resume: false)
                if restored {
                    await resumeSnapshotSyncV2AfterAuthTransition()
                }
                _ = try? await reloadLibraryItems()
                return
            }
            await releaseAccountTransitionRequest(owner: owner, resume: false)
            await resumeSnapshotSyncV2AfterAuthTransition()
        } catch is CancellationError {
            authUIState = .failed("Appleでのサインインがキャンセルされました")
            let restored = await restoreSessionAfterAppleFailure(
                fallback: previousSession,
                requestOwner: owner
            )
            if restored {
                await releaseAccountTransitionRequest(owner: owner, resume: false)
                await resumeSnapshotSyncV2AfterAuthTransition()
            } else {
                await releaseAccountTransitionRequest(owner: owner, resume: !oldScopeParked)
            }
            _ = try? await reloadLibraryItems()
        } catch {
            authUIState = .failed("Appleでのサインインを完了できませんでした")
            let restored = await restoreSessionAfterAppleFailure(
                fallback: previousSession,
                requestOwner: owner
            )
            if restored {
                await releaseAccountTransitionRequest(owner: owner, resume: false)
                await resumeSnapshotSyncV2AfterAuthTransition()
            } else {
                await releaseAccountTransitionRequest(owner: owner, resume: !oldScopeParked)
            }
            _ = try? await reloadLibraryItems()
        }
    }

    func signOutFromFuminiwa() async {
        let locallyStagedAccountItems = syncV2LibraryItems
        guard let owner = await beginAccountTransitionRequest() else { return }
        let transitioned = await transitionFuminiwaSession(
            to: nil,
            authState: authSessionCoordinator == nil ? .unavailable : .signedOut,
            requestOwner: owner
        )
        guard transitioned else {
            await releaseAccountTransitionRequest(owner: owner, resume: true)
            return
        }
        // The isolated app-host composition has no auth coordinator. Preserve
        // an explicitly supplied account projection as a parked local row so
        // the same sign-out boundary remains observable in that harness.
        if authSessionCoordinator == nil {
            let parked = locallyStagedAccountItems.map { item in
                SyncV2LibraryItem(
                    workID: item.workID,
                    title: item.title,
                    availability: .localOnly,
                    accountState: .parkedDifferentAccount,
                    localGeneration: item.localGeneration,
                    remoteProgress: .parkedDifferentAccount
                )
            }
            if !parked.isEmpty {
                var rows = Dictionary(uniqueKeysWithValues: syncV2LibraryItems.map { ($0.workID, $0) })
                for item in parked where rows[item.workID] != nil {
                    rows[item.workID] = item
                }
                syncV2LibraryItems = rows.values.sorted { $0.workID.description < $1.workID.description }
            }
        }
        // The local account boundary is complete. Release the blocker before
        // touching the network so editing/navigation/import/export stay live
        // while revoke is slow or offline.
        await releaseAccountTransitionRequest(owner: owner, resume: false)
        guard let coordinator = authSessionCoordinator else {
            return
        }
        // AuthSessionCoordinator journals the exact revoke request. Do not
        // await it here; an offline failure remains pending for startup retry.
        authRevokeRetryTask = Task { @MainActor [weak self] in
            defer { self?.authRevokeRetryTask = nil }
            do {
                try await coordinator.signOut()
                if let self, authSession == nil {
                    authUIState = .signedOut
                }
            } catch {
                if let self, authSession == nil {
                    authUIState = .failed("サインアウトの同期は保留中です")
                }
            }
        }
    }

    private func parkSnapshotSyncV2AccountScope(accountID: String?) {
        // Compatibility helper for callers outside the transition adapter.
        // Durable parking is performed by SyncV2Application; this method only
        // clears account-scoped UI and deliberately retains the local WorkID.
        dismissExport()
        syncV2ParkedAccountID = accountID
        clearAccountScopedSnapshotUIForIOS()
    }

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
        return await saveNow()
    }

    func prepareForEditorSurfaceDeparture() async -> Bool {
        guard editorCommandSession.prepareForDocumentTransition() else { return false }
        defer { editorCommandSession.resumeAfterDocumentTransition() }
        return await saveNow()
    }
}
