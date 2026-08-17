import Foundation

extension IOSDocumentStore {
    func flushDeviceSyncForBackground(waitForRemote _: Bool) async -> Bool {
        _ = await saveNow()
        Task { await resumeSnapshotSyncV2() }
        return saveState == .saved
    }

    func captureAutomaticSnapshotForBackground() async {}

    func restoreFuminiwaSession() async {
        guard let coordinator = authSessionCoordinator else {
            authUIState = .unavailable
            return
        }
        do {
            authSession = try await coordinator.currentSession()
            authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
            syncV2ParkedAccountID = nil
            if authSession != nil {
                Task { @MainActor [weak self] in
                    _ = await self?.refreshRemoteCatalog(reset: true)
                }
            }
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
            let session = try await orchestrator.signIn()
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
            await resumeSnapshotSyncV2()
            _ = await refreshRemoteCatalog(reset: true)
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
            parkSnapshotSyncV2AccountScope(accountID: nil)
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

    private func parkSnapshotSyncV2AccountScope(accountID: String?) {
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
        advanceDocumentSessionGeneration()
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
