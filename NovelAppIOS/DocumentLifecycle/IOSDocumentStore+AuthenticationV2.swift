import Foundation

extension IOSDocumentStore {
    func flushDeviceSyncForBackground(waitForRemote _: Bool) async -> Bool {
        _ = await saveNow()
        Task { await resumeSnapshotSyncV2() }
        return saveState == .saved
    }

    func captureAutomaticSnapshotForBackground() async {}

    func restoreFuminiwaSession() async {
        guard !syncV2AccountTransitionRequested,
              !syncV2AccountTransitionInProgress else { return }
        syncV2AccountTransitionRequested = true
        syncV2AccountTransitionInProgress = true
        defer {
            syncV2AccountTransitionInProgress = false
            syncV2AccountTransitionRequested = false
        }
        guard let coordinator = authSessionCoordinator else {
            let previousAccountID = authSession?.accountID
            invalidateSnapshotSyncV2AccountOperations()
            parkSnapshotSyncV2AccountScope(accountID: previousAccountID)
            authSession = nil
            authUIState = .unavailable
            return
        }
        do {
            let previousScope = snapshotSyncV2AccountScope
            let previousAccountID = authSession?.accountID
            let restoredSession = try await coordinator.currentSession()
            let restoredScope = IOSSnapshotSyncV2AccountScope(
                accountID: restoredSession?.accountID,
                accountFence: restoredSession?.accountFence
            )
            if previousScope != restoredScope {
                invalidateSnapshotSyncV2AccountOperations()
                parkSnapshotSyncV2AccountScope(accountID: previousAccountID)
            }
            authSession = restoredSession
            authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
            if restoredSession != nil {
                syncV2ParkedAccountID = nil
            }
            if authSession != nil {
                Task { @MainActor [weak self] in
                    _ = await self?.refreshRemoteCatalog(reset: true)
                }
            }
        } catch {
            let previousAccountID = authSession?.accountID
            if snapshotSyncV2AccountScope != IOSSnapshotSyncV2AccountScope(
                accountID: nil,
                accountFence: nil
            ) {
                invalidateSnapshotSyncV2AccountOperations()
                parkSnapshotSyncV2AccountScope(accountID: previousAccountID)
            }
            authSession = nil
            authUIState = .failed("サインイン状態を復元できませんでした")
        }
    }

    func signInWithApple() async {
        guard !syncV2AccountTransitionRequested,
              !syncV2AccountTransitionInProgress else { return }
        guard let orchestrator = appleAuthenticationOrchestrator else {
            authUIState = .unavailable
            return
        }
        guard authUIState != .signingIn else { return }
        syncV2AccountTransitionRequested = true
        defer { syncV2AccountTransitionRequested = false }
        cancelSnapshotSyncV2BackgroundOperations()
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  !syncV2AccountTransitionInProgress else { return }
            _ = await performDocumentTransition {
                syncV2AccountTransitionInProgress = true
                defer { syncV2AccountTransitionInProgress = false }
                let previousScope = snapshotSyncV2AccountScope
                let previousAccountID = authSession?.accountID
                invalidateSnapshotSyncV2AccountOperations()
                authUIState = .signingIn
                do {
                    let session = try await orchestrator.signIn()
                    let signedInScope = IOSSnapshotSyncV2AccountScope(
                        accountID: session.accountID,
                        accountFence: session.accountFence
                    )
                    if previousScope != signedInScope {
                        parkSnapshotSyncV2AccountScope(accountID: previousAccountID)
                    }
                    authSession = session
                    authUIState = .signedIn(accountID: session.accountID)
                    syncV2ParkedAccountID = nil
                    syncV2RemoteCatalogItems = []
                    syncV2RemoteCatalogCursor = nil
                    syncV2HistoryItems = []
                    syncV2HistoryCursor = nil
                    syncV2HistoryWorkID = nil
                    syncV2HistoryLocalAvailability = .unavailable
                    syncV2HistoryOnlineAvailability = .unavailable
                    syncV2HistoryOnlineFailure = nil
                    Task { @MainActor [weak self] in
                        guard let self,
                              !syncV2AccountTransitionInProgress,
                              snapshotSyncV2AccountScope == signedInScope else { return }
                        await resumeSnapshotSyncV2()
                        guard snapshotSyncV2AccountScope == signedInScope else { return }
                        _ = await refreshRemoteCatalog(reset: true)
                    }
                } catch is CancellationError {
                    authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
                } catch {
                    authUIState = .failed("Appleでのサインインを完了できませんでした")
                }
            }
        }
    }

    func signOutFromFuminiwa() async {
        guard !syncV2AccountTransitionRequested,
              !syncV2AccountTransitionInProgress else { return }
        syncV2AccountTransitionRequested = true
        defer { syncV2AccountTransitionRequested = false }
        cancelSnapshotSyncV2BackgroundOperations()
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  !syncV2AccountTransitionInProgress else { return }
            _ = await performDocumentTransition {
                syncV2AccountTransitionInProgress = true
                defer { syncV2AccountTransitionInProgress = false }
                invalidateSnapshotSyncV2AccountOperations()
                guard let coordinator = authSessionCoordinator else {
                    let previousAccountID = authSession?.accountID
                    authSession = nil
                    authUIState = .unavailable
                    parkSnapshotSyncV2AccountScope(accountID: previousAccountID)
                    return
                }
                do {
                    try await coordinator.signOut()
                    let previousAccountID = authSession?.accountID
                    authSession = nil
                    authUIState = .signedOut
                    // Keep SQLite/CAS untouched, but park every account-scoped
                    // projection and session so another account cannot see it.
                    parkSnapshotSyncV2AccountScope(accountID: previousAccountID)
                } catch {
                    authUIState = .failed("サインアウトを完了できませんでした")
                }
            }
        }
    }

    private func parkSnapshotSyncV2AccountScope(accountID: String?) {
        // A generated package contains the previous scope's full manuscript.
        // Do not leave its share-sheet URL reachable after sign-out/switch.
        dismissExport()
        let unboundActiveWorkID = syncV2ActiveWorkID.flatMap { workID in
            syncV2LibraryItems.first {
                $0.workID == workID && $0.accountState == .unbound
            }?.workID
        }
        syncV2ParkedAccountID = accountID
        // Invalidate the old account's editor/session as well as its shelf.
        // The SQLite rows remain untouched and can only be reopened through
        // an explicit account-scoped action later.
        // An unbound work is not owned by the account being signed out. Keep
        // its WorkID available so sign-in can expose the explicit
        // "add this work to the account" action without auto-adopting it.
        syncV2ActiveWorkID = unboundActiveWorkID
        if let unboundActiveWorkID {
            userDefaults.set(unboundActiveWorkID.rawValue.uuidString, forKey: Self.lastWorkIDKey)
        } else {
            userDefaults.removeObject(forKey: Self.lastWorkIDKey)
        }
        syncV2RemoteCatalogItems = []
        syncV2RemoteCatalogCursor = nil
        syncV2RemoteCatalogError = nil
        syncV2HistoryItems = []
        syncV2HistoryCursor = nil
        syncV2HistoryWorkID = nil
        syncV2HistoryLocalAvailability = .unavailable
        syncV2HistoryOnlineAvailability = .unavailable
        syncV2HistoryOnlineFailure = nil
        syncV2LibraryItems = syncV2LibraryItems.filter {
            $0.accountState == .unbound
        }
        snapshotSyncConflict = nil
        snapshotSyncState = nil
        snapshotSyncOutcome = .offline
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
