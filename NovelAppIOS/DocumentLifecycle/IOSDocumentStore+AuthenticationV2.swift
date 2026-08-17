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
            await resumeSnapshotSyncV2()
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
            authSession = nil
            authUIState = .signedOut
        } catch {
            authUIState = .failed("サインアウトを完了できませんでした")
        }
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
