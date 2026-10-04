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
        let retainedEpisode = preservingSelection ? selectedEpisodeID.flatMap { value.episode($0) } : nil
        let retainedChapter = preservingSelection ? value.chapters.first(where: { $0.id == selectedChapterID }) : nil
        document = value
        syncV2ActiveWorkID = opened.workID
        writingProgress.install(value, workID: opened.workID.rawValue)
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
        selectedChapterID = retainedEpisode?.chapterID ?? retainedChapter?.id ?? value.chapters.first?.id
        selectedEpisodeID = retainedEpisode?.episode.id ?? retainedChapter?.episodes.first?.id ?? value.chapters.first?.episodes.first?.id
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        startupState = .ready
        saveState = .saved
        if snapshotSyncState?.workID != opened.workID {
            applySnapshotSyncV2State(nil)
        }
        return true
    }

    func applySnapshotSyncV2State(_ state: SyncUIState?) {
        guard state == nil || state?.workID == syncV2ActiveWorkID else { return }
        if state?.remoteProgress == .retryable(.historyIncomplete),
           snapshotSyncState?.remoteProgress != state?.remoteProgress {
            AccessibilityNotification.Announcement(SyncV2HistoryFetchState.conflictWaiting).post()
        }
        snapshotSyncState = state
        snapshotSyncConflict = state?.conflict
        guard let state else { return }
        if state.remoteProgress == .authenticationRequired, case .signedIn = authUIState {
            authUIState = .failed("認証の有効期限が切れました。Appleで再サインインしてください。原稿はこの端末に保存されています。")
        }
        let account = snapshotSyncV2AccountScope
        if case let .failed(reason) = state.remoteProgress {
            if presentedSyncFailures[account]?[state.workID] != reason {
                presentedSyncFailures[account, default: [:]][state.workID] = reason
                operationErrorMessage = reason.japaneseDescription
            }
        } else if state.lastFailure == nil, state.remoteProgress == .idle || state.remoteProgress == .noChanges {
            presentedSyncFailures[account]?[state.workID] = nil
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
        let operationToken = syncSessionController.beginReprojection()
        snapshotSyncV2ReprojectionTask = Task { @MainActor [weak self] in
            defer {
                self?.syncSessionController.finishReprojection(owner: operationToken)
            }
            if resumesWorker {
                try? await application.wake(reason: wakeReason)
            }
            guard let self,
                  !isSyncV2RemoteAccountTransitionActive,
                  snapshotSyncV2ReprojectionToken == operationToken,
                  matchesSyncAccount(expectedAccountScope) else { return }
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
        expectedAccountScope: WorkspaceAccountScope,
        operationToken: UUID
    ) async {
        let changes = await application.stateChanges(for: workID, until: .now.advanced(by: .seconds(30)))
        for await event in changes {
            guard event.concerns(workID) else { continue }
            guard !Task.isCancelled,
                  !isSyncV2RemoteAccountTransitionActive,
                  snapshotSyncV2ReprojectionToken == operationToken,
                  matchesSyncAccount(expectedAccountScope),
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
                  matchesRemoteSyncAccount(expectedAccountScope),
                  syncV2ActiveWorkID == workID else { return }
            applySnapshotSyncV2State(state)
            switch state.remoteProgress {
            case .pending, .syncing:
                continue
            case .readyForSafeAdoption:
                if let automaticAdoption,
                   let current = automaticAdoptionExpectation(for: workID, validatingEditorSurface: true),
                   automaticAdoption.isCurrent(current),
                   await adoptPendingSnapshotSyncV2(
                       expectedSession: automaticAdoption.session,
                       expectedEditGeneration: automaticAdoption.editGeneration,
                       expectedAccountScope: automaticAdoption.account,
                       automatically: true
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
        expectedAccountScope: WorkspaceAccountScope? = nil,
        operationToken: UUID? = nil
    ) async {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return }
        let expectedAccountScope = expectedAccountScope ?? snapshotSyncV2AccountScope
        libraryRefreshGeneration &+= 1
        let refreshGeneration = libraryRefreshGeneration
        if let workID, let state = await application.uiState(workID: workID) {
            guard !isSyncV2AccountTransitionActive,
                  libraryRefreshGeneration == refreshGeneration,
                  matchesSyncAccount(expectedAccountScope),
                  operationToken == nil || snapshotSyncV2ReprojectionToken == operationToken else {
                return
            }
            if syncV2ActiveWorkID == workID {
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
