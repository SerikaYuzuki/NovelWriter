import Foundation
import NovelCore
import NovelSync

private enum PackageOnlyMarkerDecision {
    case ready(DeviceSyncEditIntentMarker?)
    case stopped
}

extension AppState {
    func finalizePackageOnlyDeviceSync(
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        _ = await flushPendingDeviceSyncEditIntents()
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              let current = document.episode(expectedLookup.episodeID)?.episode.content else { return }
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: expectedLookup.documentSession)
        let snapshot: DeviceSyncLocalPersistenceSnapshot
        do {
            snapshot = try await runtime.editIntentStore.reconcilePreparedPackage(
                workingCopyIdentity: workingCopyIdentity,
                documentID: expectedLookup.documentSession.documentID,
                episodeID: expectedLookup.episodeID,
                actualContentDigest: SyncContentDigest(content: current)
            )
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            deviceSyncLocalDurabilityState = .failed
            return
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        if await retainPendingPackageOnlyRecoveryChoice(
            snapshot,
            current: current,
            expectedLookup: expectedLookup
        ) {
            return
        }
        let decision = await packageOnlyMarkerDecision(
            snapshot,
            current: current,
            expectedLookup: expectedLookup,
            runtime: runtime
        )
        guard case let .ready(acknowledgedMarker) = decision else { return }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        saveCoordinator.markDirty()
        guard await saveCoordinator.saveNow() else {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            deviceSyncLocalDurabilityState = .failed
            return
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        await finishPackageOnlyPersistence(
            snapshotMarker: acknowledgedMarker,
            current: current,
            workingCopyIdentity: workingCopyIdentity,
            expectedLookup: expectedLookup,
            runtime: runtime
        )
    }

    private func retainPendingPackageOnlyRecoveryChoice(
        _ snapshot: DeviceSyncLocalPersistenceSnapshot,
        current: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) async -> Bool {
        guard let marker = snapshot.marker,
              marker.resolvesPreservedSequences == snapshot.preservedMarkers.map(\.mutationSequence),
              !snapshot.preservedMarkers.isEmpty else { return false }
        saveCoordinator.markDirty()
        guard await saveCoordinator.saveNow() else {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return true }
            deviceSyncLocalDurabilityState = .failed
            return true
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return true }
        installDeviceSyncLocalRecoveryReviewIfNeeded(
            snapshot.preservedMarkers,
            packageContent: document.episode(expectedLookup.episodeID)?.episode.content ?? current
        )
        deviceSyncLocalRecoveryChoicePending = true
        deviceSyncTransferState = .localPending
        return true
    }

    private func packageOnlyMarkerDecision(
        _ snapshot: DeviceSyncLocalPersistenceSnapshot,
        current: String,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> PackageOnlyMarkerDecision {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return .stopped }
        guard let marker = snapshot.marker else { return .ready(nil) }
        let currentDigest = SyncContentDigest(content: current)
        guard marker.replicaID == runtime.replicaID,
              marker.localWorkingCopyID == nil,
              marker.workID == nil,
              let committed = snapshot.committedPackage else {
            deviceSyncLocalDurabilityState = .failed
            return .stopped
        }
        if marker.contentDigest == currentDigest, marker.content == current {
            return .ready(marker)
        }
        if marker.mutationSequence > committed.sequence,
           committed.contentDigest == currentDigest {
            let recovery = await recoverPackageOnlyDeviceSyncMarker(
                marker,
                replacing: current,
                expectedLookup: expectedLookup
            )
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return .stopped }
            guard recovery == .recovered else {
                deviceSyncLocalDurabilityState = .failed
                return .stopped
            }
            return .ready(marker)
        }
        if committed.sequence > marker.mutationSequence,
           committed.contentDigest == currentDigest {
            return .ready(marker)
        }
        deviceSyncLocalDurabilityState = .failed
        return .stopped
    }

    private func finishPackageOnlyPersistence(
        snapshotMarker: DeviceSyncEditIntentMarker?,
        current: String,
        workingCopyIdentity: String,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        do {
            if let snapshotMarker {
                try await runtime.editIntentStore.remove(snapshotMarker)
            }
            var remaining = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: workingCopyIdentity,
                documentID: expectedLookup.documentSession.documentID,
                episodeID: expectedLookup.episodeID
            )
            remaining = try await acknowledgePackageOnlyCheckpointIfNeeded(
                remaining,
                workingCopyIdentity: workingCopyIdentity,
                expectedLookup: expectedLookup,
                runtime: runtime
            )
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            applyPackageOnlyPersistenceResult(remaining, current: current, expectedLookup: expectedLookup)
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            deviceSyncLocalDurabilityState = .failed
        }
    }

    private func acknowledgePackageOnlyCheckpointIfNeeded(
        _ snapshot: DeviceSyncLocalPersistenceSnapshot,
        workingCopyIdentity: String,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        guard let checkpoint = snapshot.committedPackage,
              checkpoint.containsLocalEditIntent,
              checkpoint.contentDigest == SyncContentDigest(
                  content: document.episode(expectedLookup.episodeID)?.episode.content ?? ""
              ) else { return snapshot }
        return try await runtime.editIntentStore.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: expectedLookup.documentSession.documentID,
            episodeID: expectedLookup.episodeID,
            throughSequence: checkpoint.sequence,
            contentDigest: checkpoint.contentDigest
        )
    }

    private func applyPackageOnlyPersistenceResult(
        _ remaining: DeviceSyncLocalPersistenceSnapshot,
        current: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        if !remaining.preservedMarkers.isEmpty {
            installDeviceSyncLocalRecoveryReviewIfNeeded(
                remaining.preservedMarkers,
                packageContent: document.episode(expectedLookup.episodeID)?.episode.content ?? current
            )
            deviceSyncTransferState = .localPending
        } else if remaining.marker == nil, pendingDeviceSyncEditIntentMarker == nil {
            deviceSyncLocalDurabilityState = .notApplicable
            deviceSyncTransferState = .notApplicable
            deviceSyncEditIntentLineage = nil
        } else {
            deviceSyncLocalDurabilityState = .failed
        }
    }

    private func recoverPackageOnlyDeviceSyncMarker(
        _ marker: DeviceSyncEditIntentMarker,
        replacing previousContent: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) async -> PackageOnlyDeviceSyncRecovery {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDeviceSyncLookupIdentity == expectedLookup,
                  document.episode(expectedLookup.episodeID)?.episode.content == previousContent,
                  beginDocumentTransition() else { return .preserveMarker }
            defer { endDocumentTransition() }
            let committed: String
            switch captureCommittedTextForDeviceSync() {
            case let .captured(content):
                committed = content
            case .notActive:
                committed = previousContent
            case .compositionInProgress:
                return .preserveMarker
            }
            guard document.episode(expectedLookup.episodeID)?.episode.content == committed else {
                return .preserveMarker
            }
            guard committed == previousContent else { return .packageWins }
            guard let currentChapterID = document.episode(expectedLookup.episodeID)?.chapterID else {
                return .preserveMarker
            }
            installDeviceSyncEpisodeContent(
                marker.content,
                chapterID: currentChapterID,
                episodeID: expectedLookup.episodeID,
                advancesEditorGeneration: true
            )
            return .recovered
        }
    }
}
