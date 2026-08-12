import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    func completeDeviceSyncLocalRecoveryPreflight(
        for expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Bool {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
        let episodeID = expectedLookup.editingToken.episodeID
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(
            for: expectedLookup.editingToken.documentSession.workingCopyID
        )
        guard let content = document.episode(episodeID)?.episode.content else { return false }
        let digest = SyncContentDigest(content: content)
        let snapshot: IOSDeviceSyncLocalPersistenceSnapshot
        do {
            snapshot = try await runtime.editIntentStore.reconcilePreparedPackage(
                workingCopyIdentity: workingCopyIdentity,
                documentID: document.id,
                episodeID: episodeID,
                actualContentDigest: digest
            )
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
        seedDeviceSyncLocalPersistenceSequence(snapshot, episodeID: episodeID)
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
        from snapshot: IOSDeviceSyncLocalPersistenceSnapshot
    ) {
        let preservedSequences = snapshot.preservedMarkers.map(\.mutationSequence)
        deviceSyncLocalRecoveryChoicePending = !preservedSequences.isEmpty
            && snapshot.marker?.resolvesPreservedSequences == preservedSequences
    }

    private func seedDeviceSyncLocalPersistenceSequence(
        _ snapshot: IOSDeviceSyncLocalPersistenceSnapshot,
        episodeID: EpisodeID
    ) {
        guard let session = currentDocumentSessionToken else { return }
        let scope = deviceSyncLocalMutationScope(session: session, episodeID: episodeID)
        deviceSyncEditIntentGeneration = max(deviceSyncEditIntentGeneration, snapshot.highestSequence)
        if let marker = snapshot.marker {
            let existing = deviceSyncMutationSequences[scope]?[marker.contentDigest]
            deviceSyncMutationSequences[scope, default: [:]][marker.contentDigest] = IOSDeviceSyncLocalMutation(
                sequence: max(existing?.sequence ?? 0, marker.mutationSequence),
                containsLocalEditIntent: true
            )
        }
        if let committed = snapshot.committedPackage {
            let existing = deviceSyncMutationSequences[scope]?[committed.contentDigest]
            deviceSyncMutationSequences[scope, default: [:]][committed.contentDigest] = IOSDeviceSyncLocalMutation(
                sequence: max(existing?.sequence ?? 0, committed.sequence),
                containsLocalEditIntent: committed.containsLocalEditIntent
                    || existing?.containsLocalEditIntent == true
            )
        }
    }

    private func reconcileDeviceSyncLocalRecoverySnapshot(
        _ snapshot: IOSDeviceSyncLocalPersistenceSnapshot,
        packageContent: String,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
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
        _ marker: IOSDeviceSyncEditIntentMarker,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) -> Bool {
        marker.workingCopyIdentity == deviceSyncWorkingCopyIdentity(
            for: expectedLookup.editingToken.documentSession.workingCopyID
        )
            && marker.documentID == document.id
            && marker.episodeID == expectedLookup.editingToken.episodeID
            && marker.replicaID == runtime.replicaID
    }

    private func preserveDeviceSyncMarkerForReview(
        _ marker: IOSDeviceSyncEditIntentMarker,
        packageContent: String,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
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
            deviceSyncLocalRecoveryReview = IOSDeviceSyncLocalRecoveryReview(
                packageContent: packageContent,
                preservedMarkers: evidence
            )
            deviceSyncState = .needsReview
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }

    func installDeviceSyncLocalRecoveryReviewIfNeeded(
        _ markers: [IOSDeviceSyncEditIntentMarker],
        packageContent: String
    ) {
        guard !markers.isEmpty else { return }
        deviceSyncLocalRecoveryReview = IOSDeviceSyncLocalRecoveryReview(
            packageContent: packageContent,
            preservedMarkers: markers
        )
        deviceSyncLocalDurabilityState = saveState == .saved ? .saved : .pending
        deviceSyncState = .needsReview
    }

    private func installDeviceSyncLocalRecoveryMarker(
        _ marker: IOSDeviceSyncEditIntentMarker,
        replacing previousContent: String,
        expectedLookup: IOSDeviceSyncLookupIdentity
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDeviceSyncLookupIdentity == expectedLookup,
                  document.episode(expectedLookup.editingToken.episodeID)?.episode.content == previousContent,
                  beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            let committedContent: String
            switch editorCommandSession.captureActiveCommittedText() {
            case let .captured(content):
                committedContent = content
            case .notActive:
                committedContent = previousContent
            case .compositionInProgress:
                return false
            }
            guard committedContent == previousContent,
                  document.episode(expectedLookup.editingToken.episodeID)?.episode.content == previousContent,
                  let chapterID = document.episode(expectedLookup.editingToken.episodeID)?.chapterID else {
                return false
            }
            installDeviceSyncEpisodeContent(
                marker.content,
                chapterID: chapterID,
                episodeID: expectedLookup.editingToken.episodeID,
                advancesEditorGeneration: true
            )
            guard await saveCoordinator.saveNow(),
                  document.episode(expectedLookup.editingToken.episodeID)?.episode.content == marker.content else {
                return false
            }
            return true
        }
    }

    private func replaceSupersededDeviceSyncMarker(
        _ previous: IOSDeviceSyncEditIntentMarker,
        with content: String,
        checkpoint: IOSDeviceSyncPackageCheckpoint,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Bool {
        guard let session = currentDocumentSessionToken else { return false }
        registerDeviceSyncContentMutation(
            content,
            episodeID: previous.episodeID,
            containsLocalEditIntent: true,
            forcesNewSequence: true
        )
        let scope = deviceSyncLocalMutationScope(session: session, episodeID: previous.episodeID)
        guard let mutation = deviceSyncMutationSequences[scope]?[checkpoint.contentDigest],
              mutation.sequence > checkpoint.sequence else {
            deviceSyncLocalDurabilityState = .failed
            return false
        }
        let replacement = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
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
