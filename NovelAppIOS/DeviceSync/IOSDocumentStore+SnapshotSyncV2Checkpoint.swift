import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

extension IOSDocumentStore {
    @discardableResult
    func checkpointSnapshotSyncV2(
        _ value: NovelDocument,
        reason: SyncV2CheckpointReason = .autosave,
        resources: [PortableResource]? = nil
    ) async -> Bool {
        guard let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        let expectedSession = currentDocumentSessionToken
        let expectedAccountScope = snapshotSyncV2AccountScope
        let matchesExpectedSource: () -> Bool = { [weak self] in
            guard let self else { return false }
            return currentDocumentSessionToken == expectedSession
                && syncV2ActiveWorkID == workID
                && snapshotSyncV2AccountScope == expectedAccountScope
        }
        do {
            guard let syncAttachments = currentV2Attachments() else {
                operationErrorMessage = "資料の本文を読み込めないため、端末への保存を中止しました。"
                snapshotSyncOutcome = .failed
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
                snapshotSyncOutcome = .failed
                saveState = .failed
                return false
            }
            let result = try await application.checkpoint(
                workID: workID, document: value, reason: reason,
                documentCreatedAt: documentCreatedAt,
                attachments: syncAttachments,
                resources: localResources
            )
            // A checkpoint result is already the local durable projection,
            // including pending/offline worker state.  Publish it before the
            // worker can move on so ProjectHome and the editor share wording.
            // The source CAS prevents a late result from a previous session or
            // account fence from repainting the current work.
            guard matchesExpectedSource() else { return false }
            applySnapshotSyncV2State(result.state)
            saveState = .saved
            return true
        } catch {
            guard matchesExpectedSource() else { return false }
            snapshotSyncOutcome = .failed
            saveState = .failed
            return false
        }
    }

    func resumeSnapshotSyncV2() async {
        guard !isSyncV2RemoteAccountTransitionActive,
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
            resumesWorker: true
        )
    }

    @discardableResult
    func synchronizeSnapshotSyncV2() async -> Bool {
        guard !isSyncV2RemoteAccountTransitionActive,
              let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        guard syncV2LibraryItems.first(where: { $0.workID == workID })?.accountState
            != .parkedDifferentAccount else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let result = try await application.synchronize(workID: workID)
            guard !isSyncV2RemoteAccountTransitionActive,
                  syncV2ActiveWorkID == workID,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            applySnapshotSyncV2State(result.state)
            return true
        } catch {
            if !isSyncV2RemoteAccountTransitionActive,
               syncV2ActiveWorkID == workID,
               snapshotSyncV2AccountScope == expectedAccountScope {
                snapshotSyncOutcome = .offline
            }
            return false
        }
    }
}
