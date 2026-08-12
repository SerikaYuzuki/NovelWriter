import Foundation
import NovelCore
import NovelSync

extension AppState {
    func completeDeviceSyncLocalRecoveryPreflight(
        for expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: expectedLookup.documentSession)
        guard let content = document.episode(expectedLookup.episodeID)?.episode.content else {
            return false
        }
        let digest = SyncContentDigest(content: content)
        let snapshot: DeviceSyncLocalPersistenceSnapshot
        do {
            snapshot = try await runtime.editIntentStore.reconcilePreparedPackage(
                workingCopyIdentity: workingCopyIdentity,
                documentID: expectedLookup.documentSession.documentID,
                episodeID: expectedLookup.episodeID,
                actualContentDigest: digest
            )
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
        seedDeviceSyncLocalPersistenceSequence(snapshot, episodeID: expectedLookup.episodeID)
        updateDeviceSyncLocalRecoveryChoice(from: snapshot)
        installDeviceSyncLocalRecoveryReviewIfNeeded(
            snapshot.preservedMarkers,
            packageContent: content
        )
        if snapshot.marker == nil,
           let committed = snapshot.committedPackage,
           committed.containsLocalEditIntent,
           committed.contentDigest == digest {
            deviceSyncLocalDurabilityState = .pending
        }
        guard await reconcileDeviceSyncLocalRecoverySnapshot(
            snapshot,
            packageContent: content,
            expectedLookup: expectedLookup,
            runtime: runtime
        ) else { return false }
        guard deviceSyncPreparationSurfaceMatches(
            currentDeviceSyncLookupIdentity,
            expectedLookup
        ) else { return false }
        deviceSyncLocalRecoveryPending = false
        return true
    }

    func updateDeviceSyncLocalRecoveryChoice(
        from snapshot: DeviceSyncLocalPersistenceSnapshot
    ) {
        let preservedSequences = snapshot.preservedMarkers.map(\.mutationSequence)
        deviceSyncLocalRecoveryChoicePending = !preservedSequences.isEmpty
            && snapshot.marker?.resolvesPreservedSequences == preservedSequences
    }

    private func seedDeviceSyncLocalPersistenceSequence(
        _ snapshot: DeviceSyncLocalPersistenceSnapshot,
        episodeID: EpisodeID
    ) {
        let scope = deviceSyncLocalMutationScope(
            session: documentSessionToken,
            episodeID: episodeID
        )
        deviceSyncEditIntentGeneration = max(
            deviceSyncEditIntentGeneration,
            snapshot.highestSequence
        )
        if let marker = snapshot.marker {
            let existing = deviceSyncMutationSequences[scope]?[marker.contentDigest]
            deviceSyncMutationSequences[scope, default: [:]][marker.contentDigest] = DeviceSyncLocalMutation(
                sequence: max(existing?.sequence ?? 0, marker.mutationSequence),
                containsLocalEditIntent: true
            )
        }
        if let committed = snapshot.committedPackage {
            let existing = deviceSyncMutationSequences[scope]?[committed.contentDigest]
            deviceSyncMutationSequences[scope, default: [:]][committed.contentDigest] = DeviceSyncLocalMutation(
                sequence: max(existing?.sequence ?? 0, committed.sequence),
                containsLocalEditIntent: committed.containsLocalEditIntent
                    || existing?.containsLocalEditIntent == true
            )
        }
    }

    private func reconcileDeviceSyncLocalRecoverySnapshot(
        _ snapshot: DeviceSyncLocalPersistenceSnapshot,
        packageContent: String,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        guard let marker = snapshot.marker else { return true }
        guard deviceSyncRecoveryMarkerMatchesScope(
            marker,
            expectedLookup: expectedLookup,
            runtime: runtime
        ) else {
            return await preserveDeviceSyncMarkerForReview(
                marker,
                packageContent: packageContent,
                expectedLookup: expectedLookup,
                runtime: runtime
            )
        }
        let packageDigest = SyncContentDigest(content: packageContent)
        guard let committed = snapshot.committedPackage else {
            return await preserveDeviceSyncMarkerForReview(
                marker,
                packageContent: packageContent,
                expectedLookup: expectedLookup,
                runtime: runtime
            )
        }
        if marker.mutationSequence > committed.sequence {
            guard committed.contentDigest == packageDigest || marker.contentDigest == packageDigest else {
                return await preserveDeviceSyncMarkerForReview(
                    marker,
                    packageContent: packageContent,
                    expectedLookup: expectedLookup,
                    runtime: runtime
                )
            }
            guard marker.contentDigest != packageDigest else { return true }
            return await installDeviceSyncLocalRecoveryMarker(
                marker,
                replacing: packageContent,
                expectedLookup: expectedLookup
            )
        }
        guard marker.contentDigest != packageDigest else { return true }
        guard committed.sequence > marker.mutationSequence,
              committed.contentDigest == packageDigest else {
            return await preserveDeviceSyncMarkerForReview(
                marker,
                packageContent: packageContent,
                expectedLookup: expectedLookup,
                runtime: runtime
            )
        }
        return await replaceSupersededDeviceSyncMarker(
            marker,
            with: packageContent,
            checkpoint: committed,
            expectedLookup: expectedLookup,
            runtime: runtime
        )
    }

    private func deviceSyncRecoveryMarkerMatchesScope(
        _ marker: DeviceSyncEditIntentMarker,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) -> Bool {
        marker.workingCopyIdentity == deviceSyncWorkingCopyIdentity(for: expectedLookup.documentSession)
            && marker.documentID == expectedLookup.documentSession.documentID
            && marker.episodeID == expectedLookup.episodeID
            && marker.replicaID == runtime.replicaID
    }

    private func preserveDeviceSyncMarkerForReview(
        _ marker: DeviceSyncEditIntentMarker,
        packageContent: String,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        do {
            try await runtime.editIntentStore.preserveForReview(marker)
            let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: marker.workingCopyIdentity,
                documentID: marker.documentID,
                episodeID: marker.episodeID
            )
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
            installDeviceSyncLocalRecoveryReviewIfNeeded(
                snapshot.preservedMarkers,
                packageContent: packageContent
            )
            return true
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
            let evidence = (deviceSyncLocalRecoveryReview?.preservedMarkers ?? []) + [marker]
            deviceSyncLocalRecoveryReview = DeviceSyncLocalRecoveryReview(
                packageContent: packageContent,
                preservedMarkers: evidence
            )
            deviceSyncState = .needsReview
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }

    func installDeviceSyncLocalRecoveryReviewIfNeeded(
        _ markers: [DeviceSyncEditIntentMarker],
        packageContent: String
    ) {
        guard !markers.isEmpty else { return }
        deviceSyncLocalRecoveryReview = DeviceSyncLocalRecoveryReview(
            packageContent: packageContent,
            preservedMarkers: markers
        )
        deviceSyncLocalDurabilityState = saveState == .saved ? .saved : .pending
        deviceSyncState = .needsReview
    }

    private func installDeviceSyncLocalRecoveryMarker(
        _ marker: DeviceSyncEditIntentMarker,
        replacing previousContent: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDeviceSyncLookupIdentity == expectedLookup,
                  document.episode(expectedLookup.episodeID)?.episode.content == previousContent,
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            let committedContent: String
            switch captureCommittedTextForDeviceSync() {
            case let .captured(content):
                committedContent = content
            case .notActive:
                committedContent = previousContent
            case .compositionInProgress:
                return false
            }
            guard committedContent == previousContent,
                  document.episode(expectedLookup.episodeID)?.episode.content == previousContent,
                  let chapterID = document.episode(expectedLookup.episodeID)?.chapterID else {
                return false
            }
            installDeviceSyncEpisodeContent(
                marker.content,
                chapterID: chapterID,
                episodeID: expectedLookup.episodeID,
                advancesEditorGeneration: true
            )
            guard await saveCoordinator.saveNow(),
                  document.episode(expectedLookup.episodeID)?.episode.content == marker.content else {
                return false
            }
            return true
        }
    }

    private func replaceSupersededDeviceSyncMarker(
        _ previous: DeviceSyncEditIntentMarker,
        with content: String,
        checkpoint: DeviceSyncPackageCheckpoint,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        registerDeviceSyncContentMutation(
            content,
            episodeID: previous.episodeID,
            containsLocalEditIntent: true,
            forcesNewSequence: true
        )
        let scope = deviceSyncLocalMutationScope(
            session: documentSessionToken,
            episodeID: previous.episodeID
        )
        guard let mutation = deviceSyncMutationSequences[scope]?[checkpoint.contentDigest],
              mutation.sequence > checkpoint.sequence else {
            deviceSyncLocalDurabilityState = .failed
            return false
        }
        let replacement = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: previous.workingCopyIdentity,
            documentID: previous.documentID,
            episodeID: previous.episodeID,
            editorContentGeneration: editorContentGeneration,
            mutationSequence: mutation.sequence,
            createdAt: runtime.now(),
            replicaID: previous.replicaID,
            localWorkingCopyID: previous.localWorkingCopyID,
            workID: previous.workID,
            baseContentDigest: previous.contentDigest,
            acceptedPriorPackageDigests: nil,
            content: content,
            contentDigest: checkpoint.contentDigest
        )
        do {
            _ = try await runtime.editIntentStore.save(
                replacement,
                baselinePackageDigest: checkpoint.contentDigest
            )
            return true
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }
}
