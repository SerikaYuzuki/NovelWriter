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
    func installSnapshotSyncV2Opened(
        _ opened: SyncV2OpenedWork,
        value: NovelDocument,
        preservingSelection: Bool = false
    ) -> Bool {
        guard opened.document == value,
              opened.documentCreatedAt.timeIntervalSince1970.isFinite,
              validateV2AttachmentRecords(opened.attachments),
              let portableMirror = try? SyncV2PortableMetadata.splitLocalMirrorResources(
                  opened.resources
              ) else {
            operationErrorMessage = "portable metadataが壊れているため、作品を開けませんでした。"
            snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
            return false
        }
        let retainedEpisode = preservingSelection ? workspaceModel.selectedEpisodeID.flatMap { value.episode($0) } : nil
        let retainedChapter = preservingSelection ? value.chapters.first(where: { $0.id == workspaceModel.selectedChapterID }) : nil
        workspaceModel.document = value
        workspaceModel.documentSessionToken.documentID = value.id
        workspaceModel.activeWorkID = opened.workID
        workspaceModel.documentSessionToken.workID = opened.workID
        writingProgress.install(value, workID: opened.workID.rawValue)
        documentCreatedAt = opened.documentCreatedAt
        // v2 does not derive identity from a path or create a WorkID folder.
        // Keep this URL only as the import/export compatibility boundary.
        documentURL = libraryRoot.standardizedFileURL
        _ = adoptV2AttachmentRecords(opened.attachments)
        syncV2PortableCreatedAt = portableMirror.portableCreatedAt
        syncV2PortableResources = portableMirror.resources
        userDefaults.set(opened.workID.rawValue.uuidString, forKey: Self.lastWorkIDKey)
        clearKeepBothHandoff()
        workspaceModel.selectedChapterID = retainedEpisode?.chapterID ?? retainedChapter?.id ?? value.chapters.first?.id
        workspaceModel.selectedEpisodeID = retainedEpisode?.episode.id ?? retainedChapter?.episodes.first?.id ?? value.chapters.first?.episodes.first?.id
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        startupState = .ready
        workspaceModel.saveState = .saved
        if workspaceModel.syncUIState?.workID != opened.workID {
            applySnapshotSyncV2State(nil)
        }
        return true
    }

    func applySnapshotSyncV2State(_ state: SyncUIState?) {
        guard state == nil || state?.workID == workspaceModel.activeWorkID else { return }
        let account = snapshotSyncV2AccountScope
        let projection = WorkspaceSyncProjection(
            state: state, previous: workspaceModel.syncUIState,
            presentedFailure: state.flatMap { workspaceModel.presentedSyncFailures[account]?[$0.workID] }
        )
        if projection.announcesHistoryWait {
            AccessibilityNotification.Announcement(SyncV2HistoryFetchState.conflictWaiting).post()
        }
        workspaceModel.syncUIState = state
        workspaceModel.syncConflict = state?.conflict
        guard let state else { return }
        if projection.authenticationRequired, case .signedIn = workspaceModel.authUIState {
            workspaceModel.authUIState = .failed("認証の有効期限が切れました。Appleで再サインインしてください。原稿はこの端末に保存されています。")
        }
        if let reason = projection.presentedFailure {
            workspaceModel.presentedSyncFailures[account, default: [:]][state.workID] = reason
        } else if projection.clearsPresentedFailure {
            workspaceModel.presentedSyncFailures[account]?[state.workID] = nil
        }
        if let message = projection.failureMessage {
            operationErrorMessage = message
        }
        snapshotSyncOutcome = state.lastTypedResult
    }

    func startSnapshotSyncV2Reprojection(
        _ application: SyncV2Application,
        workID: WorkID?,
        automaticAdoption: AutoAdoptionExpectation?,
        expectedAccountScope: WorkspaceAccountScope,
        resumesWorker: Bool,
        wakeReason: SyncV2WakeReason = .foreground
    ) {
        guard matchesRemoteSyncAccount(expectedAccountScope) else { return }
        let context = CheckpointCoordinator.context(of: self)
        let operationToken = syncSessionController.beginReprojection()
        snapshotSyncV2ReprojectionTask = Task { @MainActor [weak self] in
            defer {
                self?.syncSessionController.finishReprojection(owner: operationToken)
            }
            guard let self else { return }
            await workspaceCheckpointCoordinator(application).resume(
                host: self, reason: resumesWorker ? wakeReason : nil,
                isCurrent: {
                    !self.isSyncV2RemoteAccountTransitionActive
                        && self.snapshotSyncV2ReprojectionToken == operationToken
                        && self.matchesSyncAccount(expectedAccountScope)
                        && self.snapshotSyncV2Application === application
                        && CheckpointCoordinator.matches(context, host: self)
                },
                afterWake: {
                    if let workID {
                        guard workspaceModel.activeWorkID == workID else { return }
                        await reprojectAfterResume(
                            application,
                            workID: workID,
                            automaticAdoption: automaticAdoption,
                            expectedAccountScope: expectedAccountScope,
                            operationToken: operationToken
                        )
                    } else {
                        await refreshSnapshotSyncV2Projection(
                            expectedAccountScope: expectedAccountScope,
                            operationToken: operationToken
                        )
                    }
                }
            )
        }
    }

    func reprojectAfterResume(
        _ application: SyncV2Application,
        workID: WorkID,
        automaticAdoption: AutoAdoptionExpectation?,
        expectedAccountScope: WorkspaceAccountScope,
        operationToken: UUID
    ) async {
        let context = CheckpointCoordinator.context(of: self)
        var adopted = false
        await AdoptionCoordinator(application: application).reproject(
            host: self, workID: workID,
            isCurrent: {
                !self.isSyncV2RemoteAccountTransitionActive
                    && self.snapshotSyncV2ReprojectionToken == operationToken
                    && self.matchesRemoteSyncAccount(expectedAccountScope) && self.workspaceModel.activeWorkID == workID
            }, receive: { state in
                guard let state else { return false }
                self.applySnapshotSyncV2State(state)
                switch state.remoteProgress {
                case .pending, .syncing:
                    return true
                case .readyForSafeAdoption:
                    if let automaticAdoption,
                       let current = self.automaticAdoptionExpectation(for: workID, validatingEditorSurface: true),
                       automaticAdoption.isCurrent(current),
                       await self.adoptPendingSnapshotSyncV2(
                           expectedSession: automaticAdoption.session,
                           expectedEditGeneration: automaticAdoption.editGeneration,
                           expectedAccountScope: automaticAdoption.account, automatically: true
                       ) {
                        adopted = true
                        return false
                    }
                    return false
                default:
                    return false
                }
            }
        )
        guard !adopted, !Task.isCancelled, CheckpointCoordinator.matches(context, host: self),
              snapshotSyncV2ReprojectionToken == operationToken,
              matchesRemoteSyncAccount(expectedAccountScope) else { return }
        await refreshSnapshotSyncV2Projection(
            workID: workID, expectedAccountScope: expectedAccountScope, operationToken: operationToken
        )
    }

    func refreshSnapshotSyncV2Projection(
        workID: WorkID? = nil,
        expectedAccountScope: WorkspaceAccountScope? = nil,
        operationToken: UUID? = nil
    ) async {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return }
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        let context = CheckpointCoordinator.context(of: self)
        libraryRefreshGeneration &+= 1
        let refreshGeneration = libraryRefreshGeneration
        if let workID, let state = await application.uiState(workID: workID) {
            guard !isSyncV2AccountTransitionActive,
                  libraryRefreshGeneration == refreshGeneration,
                  matchesSyncAccount(expectedAccountScope),
                  operationToken == nil || snapshotSyncV2ReprojectionToken == operationToken else {
                return
            }
            if workspaceModel.activeWorkID == workID, CheckpointCoordinator.matches(context, host: self) {
                applySnapshotSyncV2State(state)
            }
        }
        guard let projection = try? await application.library() else { return }
        guard !isSyncV2AccountTransitionActive,
              libraryRefreshGeneration == refreshGeneration,
              matchesSyncAccount(expectedAccountScope),
              operationToken == nil || snapshotSyncV2ReprojectionToken == operationToken else {
            return
        }
        _ = applySnapshotSyncV2LibraryProjection(
            projection,
            expectedAccountScope: expectedAccountScope,
            refreshGeneration: refreshGeneration
        )
    }
}
