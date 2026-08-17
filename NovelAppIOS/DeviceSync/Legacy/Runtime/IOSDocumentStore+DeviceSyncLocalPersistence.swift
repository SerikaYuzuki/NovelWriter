import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    func registerDeviceSyncContentMutation(
        _ content: String,
        episodeID: EpisodeID,
        containsLocalEditIntent: Bool = true,
        forcesNewSequence: Bool = false
    ) {
        guard deviceSyncRuntime != nil,
              let session = currentDocumentSessionToken else { return }
        let scope = deviceSyncLocalMutationScope(
            session: session,
            episodeID: episodeID
        )
        let digest = SyncContentDigest(content: content)
        if !forcesNewSequence,
           let existing = deviceSyncMutationSequences[scope]?[digest],
           existing.sequence == deviceSyncEditIntentGeneration {
            if containsLocalEditIntent, !existing.containsLocalEditIntent {
                deviceSyncMutationSequences[scope]?[digest] = IOSDeviceSyncLocalMutation(
                    sequence: existing.sequence,
                    containsLocalEditIntent: true
                )
            }
            return
        }
        deviceSyncEditIntentGeneration &+= 1
        deviceSyncMutationSequences[scope, default: [:]][digest] = IOSDeviceSyncLocalMutation(
            sequence: deviceSyncEditIntentGeneration,
            containsLocalEditIntent: containsLocalEditIntent
        )
    }

    func prepareDeviceSyncPackageCheckpoints(
        for document: NovelDocument,
        at url: URL
    ) async -> IOSPreparedDeviceSyncPackageCheckpoints {
        guard let runtime = deviceSyncRuntime,
              url.standardizedFileURL == documentURL.standardizedFileURL,
              document.id == self.document.id else { return .init() }
        var result = IOSPreparedDeviceSyncPackageCheckpoints()
        guard let workingCopyID = currentDocumentSessionToken?.workingCopyID else {
            result.allPrepared = false
            return result
        }
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: workingCopyID)
        for chapter in document.chapters {
            for episode in chapter.episodes {
                let digest = SyncContentDigest(content: episode.content)
                let scope = IOSDeviceSyncLocalMutationScope(
                    workingCopyIdentity: workingCopyIdentity,
                    documentID: document.id,
                    episodeID: episode.id
                )
                guard let mutation = deviceSyncMutationSequences[scope]?[digest] else {
                    guard deviceSyncDurablePackageDigests[episode.id] != digest else { continue }
                    result.allPrepared = false
                    continue
                }
                let checkpoint = IOSDeviceSyncPackageCheckpoint(
                    protocolVersion: IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
                    workingCopyIdentity: workingCopyIdentity,
                    documentID: document.id,
                    episodeID: episode.id,
                    sequence: mutation.sequence,
                    contentDigest: digest,
                    containsLocalEditIntent: mutation.containsLocalEditIntent
                )
                do {
                    try await runtime.editIntentStore.preparePackageSave(checkpoint)
                    result.checkpoints.append(checkpoint)
                } catch {
                    result.allPrepared = false
                }
            }
        }
        return result
    }

    func commitDeviceSyncPackageCheckpoints(
        _ prepared: IOSPreparedDeviceSyncPackageCheckpoints
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime else { return true }
        var allCommitted = true
        for checkpoint in prepared.checkpoints {
            do {
                try await runtime.editIntentStore.commitPackageSave(checkpoint)
                pruneDeviceSyncMutationSequences(
                    checkpoint: checkpoint,
                    through: checkpoint.sequence
                )
            } catch {
                allCommitted = false
            }
        }
        return allCommitted
    }

    private func pruneDeviceSyncMutationSequences(
        checkpoint: IOSDeviceSyncPackageCheckpoint,
        through sequence: UInt64
    ) {
        let scope = IOSDeviceSyncLocalMutationScope(
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
        guard let entries = deviceSyncMutationSequences[scope] else { return }
        var retained: [SyncContentDigest: IOSDeviceSyncLocalMutation] = [:]
        for (digest, mutation) in entries where mutation.sequence > sequence {
            retained[digest] = mutation
        }
        deviceSyncMutationSequences[scope] = retained.isEmpty ? nil : retained
    }

    func deviceSyncLocalMutationScope(
        session: IOSDocumentSessionToken,
        episodeID: EpisodeID
    ) -> IOSDeviceSyncLocalMutationScope {
        IOSDeviceSyncLocalMutationScope(
            workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: session.workingCopyID),
            documentID: document.id,
            episodeID: episodeID
        )
    }

    func noteDeviceSyncPackageSaved(_ document: NovelDocument) {
        var digests: [EpisodeID: SyncContentDigest] = [:]
        for chapter in document.chapters {
            for episode in chapter.episodes {
                digests[episode.id] = SyncContentDigest(content: episode.content)
            }
        }
        deviceSyncDurablePackageDigests = digests
    }

    func deviceSyncDurablePackageDigest(
        for episodeID: EpisodeID,
        fallbackContent: String
    ) -> SyncContentDigest {
        deviceSyncDurablePackageDigests[episodeID] ?? SyncContentDigest(content: fallbackContent)
    }

    func markDeviceSyncLocalEditSavedIfCurrent(
        _ receipt: EpisodeLocalEditReceipt,
        content: String,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity,
        acknowledgedMutationSequence: UInt64? = nil
    ) async {
        guard let runtime = deviceSyncRuntime,
              deviceSyncContextIsCurrent(expectedIdentity),
              receipt.localWorkingCopyID == expectedIdentity.localWorkingCopyID,
              document.episode(expectedIdentity.editingToken.episodeID)?.episode.content == content,
              saveState == .saved,
              receipt.contentDigest == SyncContentDigest(content: content) else { return }
        do {
            guard try await removeAcknowledgedDeviceSyncMarkers(
                receipt: receipt,
                content: content,
                identity: expectedIdentity,
                mutationSequence: acknowledgedMutationSequence,
                runtime: runtime
            ) else {
                guard deviceSyncContextIsCurrent(expectedIdentity) else { return }
                deviceSyncLocalDurabilityState = .pending
                return
            }
            guard try await acknowledgeDeviceSyncPackageIntent(
                contentDigest: receipt.contentDigest,
                identity: expectedIdentity,
                throughSequence: acknowledgedMutationSequence,
                runtime: runtime
            ) else {
                guard deviceSyncContextIsCurrent(expectedIdentity) else { return }
                deviceSyncLocalDurabilityState = .pending
                return
            }
        } catch {
            guard deviceSyncContextIsCurrent(expectedIdentity) else { return }
            deviceSyncLocalDurabilityState = .failed
            return
        }
        let generationIsAcknowledged: Bool = if let acknowledgedMutationSequence {
            deviceSyncEditIntentGeneration <= acknowledgedMutationSequence
        } else {
            true
        }
        guard deviceSyncContextIsCurrent(expectedIdentity) else { return }
        guard document.episode(expectedIdentity.editingToken.episodeID)?.episode.content == content,
              pendingDeviceSyncEditIntentMarker == nil,
              generationIsAcknowledged else {
            deviceSyncLocalDurabilityState = .pending
            return
        }
        deviceSyncLocalDurabilityState = .saved
    }

    func acknowledgeDeviceSyncPackageIntent(
        contentDigest: SyncContentDigest,
        identity: IOSDeviceSyncEpisodeIdentity,
        throughSequence: UInt64?,
        runtime: IOSDeviceSyncRuntime
    ) async throws -> Bool {
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(
            for: identity.editingToken.documentSession.workingCopyID
        )
        let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: document.id,
            episodeID: identity.editingToken.episodeID
        )
        guard let checkpoint = snapshot.committedPackage,
              checkpoint.containsLocalEditIntent else { return true }
        guard let throughSequence,
              checkpoint.contentDigest == contentDigest,
              checkpoint.sequence <= throughSequence else { return false }
        let acknowledged = try await runtime.editIntentStore.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: document.id,
            episodeID: identity.editingToken.episodeID,
            throughSequence: checkpoint.sequence,
            contentDigest: contentDigest
        )
        return acknowledged.committedPackage?.containsLocalEditIntent != true
    }

    private func removeAcknowledgedDeviceSyncMarkers(
        receipt: EpisodeLocalEditReceipt,
        content: String,
        identity: IOSDeviceSyncEpisodeIdentity,
        mutationSequence: UInt64?,
        runtime: IOSDeviceSyncRuntime
    ) async throws -> Bool {
        let scope = (
            workingCopyIdentity: deviceSyncWorkingCopyIdentity(
                for: identity.editingToken.documentSession.workingCopyID
            ),
            documentID: document.id,
            episodeID: identity.editingToken.episodeID
        )
        let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: scope.workingCopyIdentity,
            documentID: scope.documentID,
            episodeID: scope.episodeID
        )
        guard deviceSyncContextIsCurrent(identity),
              document.episode(identity.editingToken.episodeID)?.episode.content == content else { return false }
        if let marker = snapshot.marker,
           marker.replicaID == runtime.replicaID,
           marker.localWorkingCopyID == nil || marker.localWorkingCopyID == identity.localWorkingCopyID,
           marker.workID == nil || marker.workID == identity.syncKey.workID,
           marker.contentDigest == receipt.contentDigest,
           marker.content == content,
           marker.resolvesPreservedSequences == nil,
           let mutationSequence,
           marker.mutationSequence <= mutationSequence {
            try await runtime.editIntentStore.remove(marker)
        }
        let remaining = try await runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: scope.workingCopyIdentity,
            documentID: scope.documentID,
            episodeID: scope.episodeID
        )
        guard deviceSyncContextIsCurrent(identity) else { return false }
        return remaining.marker == nil
            || remaining.marker?.resolvesPreservedSequences?.isEmpty == false
    }

    func enqueueDeviceSyncEditIntent(
        content: String,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        baseContentDigest: SyncContentDigest? = nil,
        previousContentDigest: SyncContentDigest? = nil,
        resolvesPreservedSequences: [UInt64]? = nil
    ) {
        guard let runtime = deviceSyncRuntime else { return }
        registerDeviceSyncContentMutation(
            content,
            episodeID: expectedLookup.editingToken.episodeID
        )
        let resolutionSequences = resolvesPreservedSequences
            ?? (deviceSyncLocalRecoveryChoicePending
                ? deviceSyncLocalRecoveryReview?.preservedMarkers.map(\.mutationSequence)
                : nil)
        var marker = deviceSyncEditIntentMarker(
            content: content,
            expectedLookup: expectedLookup,
            baseContentDigest: baseContentDigest,
            previousContentDigest: previousContentDigest
        )
        marker.resolvesPreservedSequences = resolutionSequences
        pendingDeviceSyncEditIntentMarker = marker
        deviceSyncLocalRecoveryChoicePending = resolutionSequences != nil
        deviceSyncLocalDurabilityState = .pending
        guard deviceSyncEditIntentTask == nil else { return }
        deviceSyncEditIntentTask = Task { @MainActor [weak self] in
            await self?.runDeviceSyncEditIntentWorker(runtime: runtime)
        }
    }

    func flushPendingDeviceSyncEditIntents() async -> Bool {
        if deviceSyncEditIntentTask == nil,
           pendingDeviceSyncEditIntentMarker != nil,
           let runtime = deviceSyncRuntime {
            deviceSyncLocalDurabilityState = .pending
            deviceSyncEditIntentTask = Task { @MainActor [weak self] in
                await self?.runDeviceSyncEditIntentWorker(runtime: runtime)
            }
        }
        while let task = deviceSyncEditIntentTask {
            await task.value
        }
        // This result describes only the pre-package WAL lane. A previous
        // journal/package failure must not hide an already durable marker or
        // prevent the next boundary from retrying journal promotion.
        return pendingDeviceSyncEditIntentMarker == nil
    }

    private func runDeviceSyncEditIntentWorker(runtime: IOSDeviceSyncRuntime) async {
        while let marker = pendingDeviceSyncEditIntentMarker {
            pendingDeviceSyncEditIntentMarker = nil
            do {
                let saved = try await runtime.editIntentStore.save(
                    marker,
                    baselinePackageDigest: marker.baseContentDigest
                        ?? deviceSyncDurablePackageDigest(
                            for: marker.episodeID,
                            fallbackContent: marker.content
                        )
                )
                deviceSyncEditIntentGeneration = max(
                    deviceSyncEditIntentGeneration,
                    saved.mutationSequence
                )
            } catch {
                if pendingDeviceSyncEditIntentMarker == nil {
                    pendingDeviceSyncEditIntentMarker = marker
                }
                deviceSyncLocalDurabilityState = .failed
                deviceSyncEditIntentTask = nil
                return
            }
        }
        deviceSyncEditIntentTask = nil
    }

    var deviceSyncEditIntentBufferedPayloadCount: Int {
        (deviceSyncEditIntentTask == nil ? 0 : 1) + (pendingDeviceSyncEditIntentMarker == nil ? 0 : 1)
    }

    func hasExactDeviceSyncEditIntent(
        content: String,
        identity: IOSDeviceSyncEpisodeIdentity
    ) async -> Bool {
        await latestExactDeviceSyncEditIntentSequence(content: content, identity: identity) != nil
    }

    func latestExactDeviceSyncEditIntentSequence(
        content: String,
        identity: IOSDeviceSyncEpisodeIdentity
    ) async -> UInt64? {
        guard let runtime = deviceSyncRuntime else { return nil }
        do {
            let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: deviceSyncWorkingCopyIdentity(
                    for: identity.editingToken.documentSession.workingCopyID
                ),
                documentID: document.id,
                episodeID: identity.editingToken.episodeID
            )
            guard let marker = snapshot.marker,
                  marker.replicaID == runtime.replicaID,
                  marker.localWorkingCopyID == nil || marker.localWorkingCopyID == identity.localWorkingCopyID,
                  marker.workID == nil || marker.workID == identity.syncKey.workID,
                  marker.contentDigest == SyncContentDigest(content: content),
                  marker.content == content else { return nil }
            return marker.mutationSequence
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
    }
}
