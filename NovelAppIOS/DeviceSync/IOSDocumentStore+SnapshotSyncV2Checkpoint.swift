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
            snapshotSyncOutcome = result.typedResult == .noChanges ? .idle : .pending
            saveState = .saved
            return true
        } catch {
            snapshotSyncOutcome = .failed
            saveState = .failed
            return false
        }
    }

    func resumeSnapshotSyncV2() async {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application else { return }
        let resumedWorkID = syncV2ActiveWorkID
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
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let result = try await application.synchronize(workID: workID)
            guard !syncV2AccountTransitionInProgress,
                  syncV2ActiveWorkID == workID,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            applySnapshotSyncV2State(result.state)
            return true
        } catch {
            if !syncV2AccountTransitionInProgress,
               syncV2ActiveWorkID == workID,
               snapshotSyncV2AccountScope == expectedAccountScope {
                snapshotSyncOutcome = .offline
            }
            return false
        }
    }
}
