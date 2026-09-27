import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

extension IOSDocumentStore {
    @discardableResult
    func openSnapshotSyncV2(workID: UUID) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return false }
        cancelSnapshotSyncV2BackgroundOperations()
        let targetWorkID = WorkID(workID)
        let expectedAccountScope = snapshotSyncV2AccountScope
        let didOpen = await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2AccountTransitionActive else { return false }
            var didOpen = false
            let transitioned = await performDocumentTransition {
                do {
                    // `performDocumentTransition` first confirms IME input and
                    // flushes a dirty editor through the local SQLite
                    // checkpoint.  It never wakes or awaits the remote worker.
                    let opened = try await application.openLocal(workID: targetWorkID)
                    guard !isSyncV2AccountTransitionActive,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          opened.workID == targetWorkID,
                          let value = opened.document else { return }
                    guard installSnapshotSyncV2Opened(opened, value: value) else { return }
                    let state = await application.uiState(workID: opened.workID)
                    guard !isSyncV2AccountTransitionActive,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2ActiveWorkID == targetWorkID else { return }
                    applySnapshotSyncV2State(state)
                    didOpen = true
                } catch {
                    operationErrorMessage = "作品を安全に開けませんでした。"
                }
            }
            return transitioned && didOpen
        }
        guard didOpen else { return false }
        scheduleAutomaticAdoptionAfterCleanOpen(
            application,
            workID: targetWorkID
        )
        return true
    }

    /// Opens a remote-only catalog row without making the current editor wait
    /// for HTTP. Download/verification is performed in the application layer;
    /// only the final, session-checked install crosses the document gate.
    /// Returning true means the request was accepted, not that remote bytes
    /// have already become the active editor.
    @discardableResult
    func startRemoteOnlySnapshotSyncV2Open(workID: WorkID) async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application,
              syncV2LibraryItems.contains(where: {
                  $0.workID == workID && $0.availability == .remoteOnly
              }),
              snapshotSyncV2RemoteOnlyOpenTask == nil else { return false }
        let expectedSession = currentDocumentSessionToken
        let expectedAccountScope = snapshotSyncV2AccountScope
        let operationToken = UUID()
        snapshotSyncV2RemoteOnlyOpenToken = operationToken
        snapshotSyncV2RemoteOnlyOpenTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   snapshotSyncV2RemoteOnlyOpenToken == operationToken {
                    snapshotSyncV2RemoteOnlyOpenToken = nil
                    snapshotSyncV2RemoteOnlyOpenTask = nil
                }
            }
            do {
                let opened = try await application.open(workID: workID)
                let matchesRequestedWork = acceptsSnapshotSyncV2RemoteOnlyOpen(
                    opened,
                    requestedWorkID: workID
                )
                guard matchesRequestedWork,
                      !Task.isCancelled,
                      let self,
                      !isSyncV2RemoteAccountTransitionActive,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      snapshotSyncV2AccountScope == expectedAccountScope else { return }
                _ = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          !isSyncV2RemoteAccountTransitionActive,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2LibraryItems.contains(where: { $0.workID == workID }) else {
                        return false
                    }
                    var installed = false
                    let transitioned = await performDocumentTransition {
                        guard snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                              !isSyncV2RemoteAccountTransitionActive,
                              currentDocumentSessionToken == expectedSession,
                              snapshotSyncV2AccountScope == expectedAccountScope,
                              acceptsSnapshotSyncV2RemoteOnlyOpen(
                                  opened,
                                  requestedWorkID: workID
                              ),
                              let value = opened.document else {
                            throw SyncV2ApplicationError.workNotFound
                        }
                        guard installSnapshotSyncV2Opened(opened, value: value) else {
                            throw SyncV2ApplicationError.invalidRuntimeMode
                        }
                        let state = await application.uiState(workID: opened.workID)
                        guard snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                              !isSyncV2RemoteAccountTransitionActive,
                              snapshotSyncV2AccountScope == expectedAccountScope,
                              syncV2ActiveWorkID == workID else { return }
                        applySnapshotSyncV2State(state)
                        snapshotSyncV2RemoteOnlyReadyWorkID = opened.workID
                        installed = true
                    }
                    return transitioned && installed
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !isSyncV2RemoteAccountTransitionActive,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      currentDocumentSessionToken == expectedSession,
                      snapshotSyncV2AccountScope == expectedAccountScope else { return }
                operationErrorMessage = "作品を取得できませんでした。接続が戻ると再試行できます。"
            }
        }
        return true
    }
}
