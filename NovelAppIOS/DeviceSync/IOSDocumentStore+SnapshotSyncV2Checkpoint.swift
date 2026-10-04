import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import NovelWorkspace

extension IOSDocumentStore {
    func runAutomaticSnapshotSyncV2() async {
        guard startupState == .ready,
              let workID = syncV2ActiveWorkID,
              let application = snapshotSyncV2Application else { return }
        let session = currentDocumentSessionToken
        let account = snapshotSyncV2AccountScope
        await application.observeForegroundSynchronization(workID: workID) { [weak self] in
            await self?.refreshAutomaticSnapshotSyncV2(session: session, account: account)
        }
    }

    private func refreshAutomaticSnapshotSyncV2(
        session: WorkspaceSessionToken?, account: WorkspaceAccountScope
    ) async {
        guard !Task.isCancelled, currentDocumentSessionToken == session,
              matchesSyncAccount(account),
              snapshotSyncV2ReprojectionTask == nil else { return }
        await resumeSnapshotSyncV2(reason: nil)
    }

    @discardableResult
    func checkpointSnapshotSyncV2(
        _ value: NovelDocument,
        reason: SyncV2CheckpointReason = .autosave,
        resources: [PortableResource]? = nil,
        acknowledgeLocalCommit: Bool = false
    ) async -> Bool {
        guard syncV2KeepBothPendingWorkID == nil,
              let application = snapshotSyncV2Application,
              syncV2ActiveWorkID != nil else { return false }
        guard let syncAttachments = currentV2Attachments() else {
            operationErrorMessage = "資料の本文を読み込めないため、端末への保存を中止しました。"
            snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
            saveState = .failed
            return false
        }
        let localResources: [PortableResource]?
        do {
            localResources = if let resources {
                try SyncV2PortableMetadata.resourcesForLocalMirror(
                    resources,
                    portableCreatedAt: syncV2PortableCreatedAt
                )
            } else {
                nil
            }
        } catch {
            operationErrorMessage = "portable metadataを安全に保存できないため、端末への保存を中止しました。"
            snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
            saveState = .failed
            return false
        }
        switch await workspaceCheckpointCoordinator(application).save(
            host: self, document: value, reason: reason, createdAt: documentCreatedAt,
            attachments: syncAttachments, resources: localResources,
            isCurrent: { self.snapshotSyncV2Application === application },
            applyCommitted: { result in
                self.applySnapshotSyncV2State(result.state)
                self.applyCheckpointSaveState(result.state)
            },
            applyFailure: {
                self.snapshotSyncOutcome = .failure(.fatal(.invalidLocalState))
                self.saveState = .failed
            }
        ) {
        case .committed:
            return true
        case .failed:
            return false
        case let .stale(committedLocally):
            return acknowledgeLocalCommit && committedLocally
        }
    }

    func resumeSnapshotSyncV2(reason: SyncV2WakeReason? = .foreground) async {
        guard !isSnapshotSyncInFlight, !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application else { return }
        let resumedWorkID = syncV2ActiveWorkID
        // A parked lane is intentionally local-only.  Reprojection may still
        // refresh its local shelf, but must not wake a remote worker or offer
        // adoption while no matching account/fence is active.
        if let resumedWorkID,
           syncV2LibraryItems.first(where: { $0.workID == resumedWorkID })?.accountState
           == .parkedDifferentAccount {
            await refreshSnapshotSyncV2Projection(
                workID: resumedWorkID,
                expectedAccountScope: snapshotSyncV2AccountScope
            )
            return
        }
        let expectedAccountScope = snapshotSyncV2AccountScope
        let automaticAdoption = resumedWorkID.flatMap {
            automaticAdoptionExpectation(
                for: $0,
                validatingEditorSurface: true
            )
        }
        // resumePending only wakes the durable worker.  Keep lifecycle/UI
        // non-blocking, then observe the actor's projected terminal state so
        // conflict/adoption/status changes become visible after the worker.
        startSnapshotSyncV2Reprojection(
            application,
            workID: resumedWorkID,
            automaticAdoption: automaticAdoption,
            expectedAccountScope: expectedAccountScope,
            resumesWorker: reason != nil,
            wakeReason: reason ?? .foreground
        )
    }

    @discardableResult
    func synchronizeSnapshotSyncV2() async -> Bool {
        guard !isSnapshotSyncInFlight, !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        guard syncV2LibraryItems.first(where: { $0.workID == workID })?.accountState
            != .parkedDifferentAccount else { return false }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        return await workspaceCheckpointCoordinator(application).explicitlySync(
            host: self,
            permitsRemoteCompletion: {
                !self.isSyncV2RemoteAccountTransitionActive && self.snapshotSyncV2Application === application
            },
            saveLocally: { context in
                await self.documentOperationGate.perform {
                    guard CheckpointCoordinator.matches(context, host: self) else { return false }
                    return await self.prepareForEditorSurfaceDeparture(clearProofreadingHighlights: true)
                }
            },
            adoptionContext: {
                self.automaticAdoptionExpectation(for: workID, validatingEditorSurface: true)
            },
            didQueue: { result, cleanContext in
                self.applySnapshotSyncV2State(result.state)
                if case .failure = result.typedResult {
                    self.operationErrorMessage = result.state.japaneseLabel
                    return false
                }
                self.startSnapshotSyncV2Reprojection(
                    application, workID: workID, automaticAdoption: cleanContext,
                    expectedAccountScope: self.snapshotSyncV2AccountScope, resumesWorker: false
                )
                return true
            },
            failed: {
                self.operationErrorMessage = "同期を開始できませんでした。サインインと作品の同期設定を確認してください。原稿はこの端末に保存されています。"
            }
        )
    }
}
