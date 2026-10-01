import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import SwiftUI

extension IOSDocumentStore {
    @discardableResult
    func openSnapshotSyncV2(workID: UUID) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return false }
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
                          opened.workID == targetWorkID else { return }
                    guard let value = opened.document else { throw SyncV2ApplicationError.workNotFound }
                    guard installSnapshotSyncV2Opened(opened, value: value) else { return }
                    let state = await application.uiState(workID: opened.workID)
                    guard !isSyncV2AccountTransitionActive,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2ActiveWorkID == targetWorkID else { return }
                    applySnapshotSyncV2State(state)
                    didOpen = true
                } catch {
                    snapshotSyncV2RemoteOnlyOpenFailure = syncV2FailureKind(error)
                    logSyncV2PresentationFailure(error)
                    operationErrorMessage = remoteOnlyOpenErrorMessage(error)
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
    func startRemoteOnlySnapshotSyncV2Open(workID: WorkID, shouldOpen: @escaping @MainActor () -> Bool = { true },
                                           onOpened: @escaping @MainActor (IOSDocumentSessionToken) -> Void = { _ in }) async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application,
              syncV2LibraryItems.contains(where: {
                  $0.workID == workID && $0.availability == .remoteOnly
              }),
              snapshotSyncV2RemoteOnlyOpenTask == nil else { return false }
        let title = syncV2LibraryItems.first(where: { $0.workID == workID })?.title ?? "作品"
        let expectedSession = currentDocumentSessionToken
        let expectedAccountScope = snapshotSyncV2AccountScope
        let operationToken = UUID()
        snapshotSyncV2RemoteOnlyOpenToken = operationToken
        snapshotSyncV2RemoteOnlyOpeningWorkID = workID
        snapshotSyncV2RemoteOnlyOpenStartedAt = Date()
        snapshotSyncV2RemoteOnlyOpenFailure = nil
        libraryNotice = nil
        snapshotSyncV2RemoteOnlyOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if snapshotSyncV2RemoteOnlyOpenToken == operationToken {
                    snapshotSyncV2RemoteOnlyOpenToken = nil
                    snapshotSyncV2RemoteOnlyOpenTask = nil
                    snapshotSyncV2RemoteOnlyOpeningWorkID = nil
                    snapshotSyncV2RemoteOnlyOpenStartedAt = nil
                }
            }
            do {
                let opened = try await openRemoteOnlyWithBackgroundTime(application, workID: workID)
                guard opened.document != nil else { throw SyncV2ApplicationError.workNotFound }
                let matchesRequestedWork = acceptsSnapshotSyncV2RemoteOnlyOpen(
                    opened,
                    requestedWorkID: workID
                )
                guard matchesRequestedWork,
                      !Task.isCancelled,
                      !isSyncV2RemoteAccountTransitionActive,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      snapshotSyncV2AccountScope == expectedAccountScope else { return }
                let installed = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          !isSyncV2RemoteAccountTransitionActive,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          currentDocumentSessionToken == expectedSession,
                          shouldOpen(),
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2LibraryItems.contains(where: { $0.workID == workID }) else {
                        return false
                    }
                    var installed = false
                    let transitioned = await performDocumentTransition {
                        guard try await application.isCurrentLocalVersion(opened) else {
                            throw SyncV2ApplicationError.safeBoundaryRejected
                        }
                        guard snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                              !isSyncV2RemoteAccountTransitionActive,
                              currentDocumentSessionToken == expectedSession,
                              shouldOpen(),
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
                        if shouldOpen(), let session = currentDocumentSessionToken {
                            onOpened(session)
                        } else {
                            libraryNotice = "『\(title)』をこの端末に取り込みました"
                        }
                        installed = true
                    }
                    return transitioned && installed
                }
                guard !Task.isCancelled, snapshotSyncV2AccountScope == expectedAccountScope else { return }
                if !installed, shouldOpen(), currentDocumentSessionToken == expectedSession {
                    let failure = SyncV2Failure.fatal(.invalidLocalState)
                    snapshotSyncV2RemoteOnlyOpenFailure = failure
                    logSyncV2PresentationFailure(failure)
                    operationErrorMessage = remoteOnlyOpenErrorMessage(failure)
                    AccessibilityNotification.Announcement(remoteOnlyOpenErrorMessage(failure)).post()
                    _ = try? await reloadLibraryItems()
                    return
                }
                let notice = "『\(title)』をこの端末に取り込みました"
                if !installed {
                    libraryNotice = notice
                }
                AccessibilityNotification.Announcement(notice).post()
                _ = try? await reloadLibraryItems()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !isSyncV2RemoteAccountTransitionActive,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      snapshotSyncV2AccountScope == expectedAccountScope else { return }
                operationErrorMessage = remoteOnlyOpenErrorMessage(error)
                snapshotSyncV2RemoteOnlyOpenFailure = syncV2FailureKind(error)
                logSyncV2PresentationFailure(error)
                AccessibilityNotification.Announcement(remoteOnlyOpenErrorMessage(error)).post()
            }
        }
        return true
    }
}
