import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

extension IOSDocumentStore {
    @discardableResult
    func installSnapshotSyncV2Opened(
        _ opened: SyncV2OpenedWork,
        value: NovelDocument
    ) -> Bool {
        guard opened.document == value,
              opened.documentCreatedAt.timeIntervalSince1970.isFinite,
              validateV2AttachmentRecords(opened.attachments),
              let portableMirror = try? SyncV2PortableMetadata.splitLocalMirrorResources(
                  opened.resources
              ) else {
            operationErrorMessage = "portable metadataが壊れているため、作品を開けませんでした。"
            snapshotSyncOutcome = .failed
            return false
        }
        document = value
        syncV2ActiveWorkID = opened.workID
        documentCreatedAt = opened.documentCreatedAt
        // v2 does not derive identity from a path or create a WorkID folder.
        // Keep this URL only as the import/export compatibility boundary.
        documentURL = libraryRoot.standardizedFileURL
        replaceAttachments(opened.attachments.map {
            Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount))
        })
        syncV2AttachmentPayloads = Dictionary(
            uniqueKeysWithValues: opened.attachments.map { ($0.fileName, $0.bytes) }
        )
        syncV2AttachmentIDs = Dictionary(
            uniqueKeysWithValues: opened.attachments.map { ($0.fileName, $0.attachmentId) }
        )
        syncV2PortableCreatedAt = portableMirror.portableCreatedAt
        syncV2PortableResources = portableMirror.resources
        userDefaults.set(opened.workID.rawValue.uuidString, forKey: Self.lastWorkIDKey)
        syncV2KeepBothPendingWorkID = nil
        selectedChapterID = value.chapters.first?.id
        selectedEpisodeID = value.chapters.first?.episodes.first?.id
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        startupState = .ready
        saveState = .saved
        applySnapshotSyncV2State(snapshotSyncState)
        return true
    }

    func applySnapshotSyncV2State(_ state: SyncUIState?) {
        snapshotSyncState = state
        snapshotSyncConflict = state?.conflict
        guard let state else { return }
        switch state.remoteProgress {
        case .idle, .noChanges:
            snapshotSyncOutcome = .idle
        case .pending:
            snapshotSyncOutcome = .pending
        case .syncing:
            snapshotSyncOutcome = .syncing
        case .needsChoice, .readyForSafeAdoption:
            snapshotSyncOutcome = .conflict
        case .offline, .authenticationRequired, .parkedDifferentAccount,
             .fenceChanged, .quarantined, .retryable:
            snapshotSyncOutcome = .offline
        case .failed, .receiptMismatch:
            snapshotSyncOutcome = .failed
        }
    }

    func startSnapshotSyncV2Reprojection(
        _ application: SyncV2Application,
        workID: WorkID?,
        automaticAdoption: AutoAdoptionExpectation?,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        resumesWorker: Bool
    ) {
        guard !syncV2AccountTransitionInProgress,
              snapshotSyncV2AccountScope == expectedAccountScope else { return }
        snapshotSyncV2ReprojectionToken = nil
        snapshotSyncV2ReprojectionTask?.cancel()
        let operationToken = UUID()
        snapshotSyncV2ReprojectionToken = operationToken
        snapshotSyncV2ReprojectionTask = Task { @MainActor [weak self] in
            defer {
                if let self, snapshotSyncV2ReprojectionToken == operationToken {
                    snapshotSyncV2ReprojectionToken = nil
                    snapshotSyncV2ReprojectionTask = nil
                }
            }
            if resumesWorker {
                try? await application.resumePending()
            }
            guard let self,
                  !syncV2AccountTransitionInProgress,
                  snapshotSyncV2ReprojectionToken == operationToken,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return }
            if let workID {
                guard syncV2ActiveWorkID == workID else { return }
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
    }

    func reprojectAfterResume(
        _ application: SyncV2Application,
        workID: WorkID,
        automaticAdoption: AutoAdoptionExpectation?,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        operationToken: UUID
    ) async {
        for _ in 0 ..< 600 {
            guard !Task.isCancelled,
                  !syncV2AccountTransitionInProgress,
                  snapshotSyncV2ReprojectionToken == operationToken,
                  snapshotSyncV2AccountScope == expectedAccountScope,
                  syncV2ActiveWorkID == workID else { return }
            guard let state = await application.uiState(workID: workID) else {
                await refreshSnapshotSyncV2Projection(
                    workID: workID,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
                return
            }
            guard snapshotSyncV2ReprojectionToken == operationToken,
                  !syncV2AccountTransitionInProgress,
                  snapshotSyncV2AccountScope == expectedAccountScope,
                  syncV2ActiveWorkID == workID else { return }
            applySnapshotSyncV2State(state)
            switch state.remoteProgress {
            case .pending, .syncing:
                try? await Task.sleep(nanoseconds: 50_000_000)
            case .readyForSafeAdoption:
                if let automaticAdoption,
                   await adoptPendingSnapshotSyncV2(
                       expectedSession: automaticAdoption.session,
                       expectedEditGeneration: automaticAdoption.editGeneration,
                       expectedAccountScope: automaticAdoption.accountScope
                   ) {
                    return
                }
                await refreshSnapshotSyncV2Projection(
                    workID: workID,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
                return
            default:
                await refreshSnapshotSyncV2Projection(
                    workID: workID,
                    expectedAccountScope: expectedAccountScope,
                    operationToken: operationToken
                )
                return
            }
        }
        await refreshSnapshotSyncV2Projection(
            workID: workID,
            expectedAccountScope: expectedAccountScope,
            operationToken: operationToken
        )
    }

    func refreshSnapshotSyncV2Projection(
        workID: WorkID? = nil,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope? = nil,
        operationToken: UUID? = nil
    ) async {
        guard !syncV2AccountTransitionInProgress,
              let application = snapshotSyncV2Application else { return }
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        libraryRefreshGeneration &+= 1
        let refreshGeneration = libraryRefreshGeneration
        // Taking library projection ownership also retires an older catalog
        // request. Its generation-mismatched defer cannot clear this latch.
        syncV2RemoteCatalogIsLoading = false
        if let workID, let state = await application.uiState(workID: workID) {
            guard !syncV2AccountTransitionInProgress,
                  libraryRefreshGeneration == refreshGeneration,
                  snapshotSyncV2AccountScope == expectedAccountScope,
                  operationToken == nil || snapshotSyncV2ReprojectionToken == operationToken else {
                return
            }
            if syncV2ActiveWorkID == workID {
                applySnapshotSyncV2State(state)
            }
        }
        guard let projection = try? await application.library() else { return }
        guard !syncV2AccountTransitionInProgress,
              libraryRefreshGeneration == refreshGeneration,
              snapshotSyncV2AccountScope == expectedAccountScope,
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
