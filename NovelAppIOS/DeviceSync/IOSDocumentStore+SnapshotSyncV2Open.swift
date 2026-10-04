import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import NovelWorkspace
import SwiftUI

extension IOSDocumentStore {
    @discardableResult
    func openSnapshotSyncV2(workID: UUID) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return false }
        snapshotSyncV2RemoteOnlyOpenFailure = nil
        operationErrorMessage = nil
        let targetWorkID = WorkID(workID)
        let expectedAccountScope = snapshotSyncV2AccountScope
        let expected = CheckpointCoordinator.context(of: self)
        let didOpen = await documentOperationGate.perform { [weak self] in
            guard let self, !isSyncV2AccountTransitionActive,
                  CheckpointCoordinator.matches(expected, host: self) else { return false }
            var didOpen = false
            let transitioned = await performDocumentTransition {
                do {
                    let prepared = operationContext
                    let coordinator = WorkOpenCoordinator(application: application)
                    guard let opened = try await coordinator.readLocal(workID: targetWorkID, isCurrent: {
                        prepared.isCurrent(self.operationContext) && self.matchesLocalSyncAccount(expectedAccountScope)
                    }) else { return }
                    didOpen = try await coordinator.installAtPreparedBoundary(
                        opened, workID: targetWorkID, host: self,
                        isCurrent: { self.matchesLocalSyncAccount(expectedAccountScope) },
                        install: { opened, _ in
                            guard let value = opened.document else { return false }
                            return self.installSnapshotSyncV2Opened(opened, value: value)
                        }, project: { self.applySnapshotSyncV2State($0) }
                    )
                } catch {
                    guard matchesLocalSyncAccount(expectedAccountScope) else { return }
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
                                           onOpened: @escaping @MainActor (WorkspaceSessionToken) -> Void = { _ in }) async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application,
              syncV2LibraryItems.contains(where: {
                  $0.workID == workID && $0.availability == .remoteOnly
              }),
              snapshotSyncV2RemoteOnlyOpenTask == nil else { return false }
        let title = syncV2LibraryItems.first(where: { $0.workID == workID })?.title ?? "作品"
        let expectedSession = currentDocumentSessionToken
        let expectedAccountScope = snapshotSyncV2AccountScope
        let operation = WorkspaceOperationContext(workID: expectedSession?.workID, session: expectedSession,
                                                  account: expectedAccountScope, editGeneration: nil)
        let operationToken = syncSessionController.beginRemoteOnlyOpen(workID: workID)
        snapshotSyncV2RemoteOnlyOpenFailure = nil
        libraryNotice = nil
        snapshotSyncV2RemoteOnlyOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishLibraryOpen(operationToken: operationToken) }
            do {
                var coordinator = WorkOpenCoordinator(application: application)
                coordinator.download = { try await self.openRemoteOnlyWithBackgroundTime(application, workID: $0) }
                guard let opened = try await coordinator.downloadRemoteOnly(
                    workID: workID,
                    isCurrent: { !self.isSyncV2RemoteAccountTransitionActive
                        && self.snapshotSyncV2RemoteOnlyOpenToken == operationToken
                        && self.matchesSyncAccount(expectedAccountScope)
                    },
                    opening: { self.libraryImportPhases[workID] = ImportPhase(stage: .opening) }
                ) else { return }
                let installed = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          !isSyncV2RemoteAccountTransitionActive,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          currentDocumentSessionToken == expectedSession,
                          shouldOpen(),
                          matchesSyncOperation(operation),
                          syncV2LibraryItems.contains(where: { $0.workID == workID }) else {
                        return false
                    }
                    var installed = false
                    let transitioned = await performDocumentTransition {
                        installed = try await coordinator.installAtPreparedBoundary(
                            opened, workID: workID, host: self, verifiesLocalVersion: true,
                            isCurrent: { self.snapshotSyncV2RemoteOnlyOpenToken == operationToken
                                && !self.isSyncV2RemoteAccountTransitionActive
                                && self.currentDocumentSessionToken == expectedSession
                                && shouldOpen() && self.matchesSyncOperation(operation)
                            },
                            install: { opened, _ in
                                guard let value = opened.document else { return false }
                                return self.installSnapshotSyncV2Opened(opened, value: value)
                            }, project: { self.applySnapshotSyncV2State($0) }
                        )
                        if installed {
                            if shouldOpen(), let session = currentDocumentSessionToken {
                                onOpened(session)
                            } else {
                                libraryNotice = "『\(title)』をこの端末に取り込みました"
                            }
                        }
                    }
                    return transitioned && installed
                }
                await reportRemoteOnlySnapshotSyncV2OpenResult(
                    installed: installed, title: title, expectedSession: expectedSession,
                    expectedAccountScope: expectedAccountScope, shouldOpen: shouldOpen
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !isSyncV2RemoteAccountTransitionActive,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      matchesSyncAccount(expectedAccountScope) else { return }
                operationErrorMessage = remoteOnlyOpenErrorMessage(error)
                snapshotSyncV2RemoteOnlyOpenFailure = syncV2FailureKind(error)
                logSyncV2PresentationFailure(error)
                AccessibilityNotification.Announcement(remoteOnlyOpenErrorMessage(error)).post()
            }
        }
        return true
    }

    private func finishLibraryOpen(operationToken: UUID) {
        syncSessionController.finishRemoteOnlyOpen(owner: operationToken, preservingPrefetchStart: true)
    }

    private func reportRemoteOnlySnapshotSyncV2OpenResult(
        installed: Bool,
        title: String,
        expectedSession: WorkspaceSessionToken?,
        expectedAccountScope: WorkspaceAccountScope,
        shouldOpen: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, matchesSyncAccount(expectedAccountScope) else { return }
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
    }
}
