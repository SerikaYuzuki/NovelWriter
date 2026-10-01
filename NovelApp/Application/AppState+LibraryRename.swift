import Foundation
import NovelSyncV2Application

extension AppState {
    func renameLibraryWork(
        _ work: StartupLibraryWork, title: String,
        expectedSession: DocumentSessionToken,
        accountScope: SnapshotSyncV2AccountScopeToken
    ) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let application = snapshotSyncV2Application,
              documentSessionToken == expectedSession,
              matchesSnapshotSyncV2AccountScope(accountScope),
              !isDocumentTransitionInProgress, !isTerminationPending,
              interactiveAuthOperationCount == 0 else { return false }
        do {
            // Join the application's per-WorkID import, outside the editor gate.
            if work.availability == .remoteOnly {
                _ = try await application.open(workID: work.workID)
            }
            let renamed = await documentOperationGate.perform { [weak self] in
                guard let self, documentSessionToken == expectedSession,
                      matchesSnapshotSyncV2AccountScope(accountScope),
                      !isDocumentTransitionInProgress, !isTerminationPending,
                      interactiveAuthOperationCount == 0,
                      editorCommandSession.prepareForDocumentTransition() else { return false }
                defer { editorCommandSession.resumeAfterDocumentTransition() }
                isDocumentTransitionInProgress = true
                defer { isDocumentTransitionInProgress = false }
                if saveState != .saved {
                    guard await saveNow() else { return false }
                }
                do {
                    try await saveCoordinator.performExclusive {
                        guard documentSessionToken == expectedSession,
                              matchesSnapshotSyncV2AccountScope(accountScope) else {
                            throw SyncV2ApplicationError.safeBoundaryRejected
                        }
                        _ = try await application.renameLocalWork(workID: work.workID, title: title)
                        guard documentSessionToken == expectedSession,
                              matchesSnapshotSyncV2AccountScope(accountScope) else {
                            throw SyncV2ApplicationError.safeBoundaryRejected
                        }
                        if currentSnapshotSyncV2WorkID == work.workID {
                            document.title = title
                        }
                    }
                    return true
                } catch {
                    operationMessage = "作品名を変更できませんでした。一覧を更新して再試行してください。"
                    return false
                }
            }
            guard renamed else { return false }
            await refreshSnapshotLibrary()
            return true
        } catch {
            operationMessage = "作品を取得できませんでした。接続を確認して再試行してください。"
            return false
        }
    }
}
