import Foundation
import NovelCore
import NovelSync

struct DeviceSyncPreparationRecovery {
    let content: String
    let identity: DeviceSyncEpisodeIdentity
    let state: EpisodeSyncState
}

enum PackageOnlyDeviceSyncRecovery: Equatable {
    case recovered
    case packageWins
    case preserveMarker
}

struct PreparedDeviceSyncPackageCheckpoints {
    var checkpoints: [DeviceSyncPackageCheckpoint] = []
    var allPrepared = true
}

extension AppState {
    func registerDeviceSyncContentMutation(
        _ content: String,
        episodeID: EpisodeID,
        containsLocalEditIntent: Bool = true,
        forcesNewSequence: Bool = false
    ) {
        guard deviceSyncRuntime != nil else { return }
        let scope = deviceSyncLocalMutationScope(
            session: documentSessionToken,
            episodeID: episodeID
        )
        let digest = SyncContentDigest(content: content)
        if !forcesNewSequence,
           let existing = deviceSyncMutationSequences[scope]?[digest],
           existing.sequence == deviceSyncEditIntentGeneration {
            if containsLocalEditIntent, !existing.containsLocalEditIntent {
                deviceSyncMutationSequences[scope]?[digest] = DeviceSyncLocalMutation(
                    sequence: existing.sequence,
                    containsLocalEditIntent: true
                )
            }
            return
        }
        deviceSyncEditIntentGeneration &+= 1
        deviceSyncMutationSequences[scope, default: [:]][digest] = DeviceSyncLocalMutation(
            sequence: deviceSyncEditIntentGeneration,
            containsLocalEditIntent: containsLocalEditIntent
        )
    }

    func prepareDeviceSyncPackageCheckpoints(
        for document: NovelDocument,
        at url: URL
    ) async -> PreparedDeviceSyncPackageCheckpoints {
        guard let runtime = deviceSyncRuntime,
              url.standardizedFileURL == documentSessionToken.documentURL.standardizedFileURL,
              document.id == documentSessionToken.documentID else { return .init() }
        var result = PreparedDeviceSyncPackageCheckpoints()
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: documentSessionToken)
        for chapter in document.chapters {
            for episode in chapter.episodes {
                let digest = SyncContentDigest(content: episode.content)
                let scope = DeviceSyncLocalMutationScope(
                    workingCopyIdentity: workingCopyIdentity,
                    documentID: document.id,
                    episodeID: episode.id
                )
                guard let mutation = deviceSyncMutationSequences[scope]?[digest] else {
                    guard deviceSyncDurablePackageDigests[episode.id] != digest else { continue }
                    result.allPrepared = false
                    continue
                }
                let checkpoint = DeviceSyncPackageCheckpoint(
                    protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
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
        _ prepared: PreparedDeviceSyncPackageCheckpoints
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
        checkpoint: DeviceSyncPackageCheckpoint,
        through sequence: UInt64
    ) {
        let scope = DeviceSyncLocalMutationScope(
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
        guard let entries = deviceSyncMutationSequences[scope] else { return }
        var retained: [SyncContentDigest: DeviceSyncLocalMutation] = [:]
        for (digest, mutation) in entries where mutation.sequence > sequence {
            retained[digest] = mutation
        }
        deviceSyncMutationSequences[scope] = retained.isEmpty ? nil : retained
    }

    func deviceSyncLocalMutationScope(
        session: DocumentSessionToken,
        episodeID: EpisodeID
    ) -> DeviceSyncLocalMutationScope {
        DeviceSyncLocalMutationScope(
            workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: session),
            documentID: session.documentID,
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
        expectedIdentity: DeviceSyncEpisodeIdentity,
        acknowledgedMutationSequence: UInt64? = nil
    ) async {
        guard let runtime = deviceSyncRuntime,
              deviceSyncContextIsCurrent(expectedIdentity),
              receipt.localWorkingCopyID == expectedIdentity.localWorkingCopyID,
              document.episode(expectedIdentity.episodeID)?.episode.content == content,
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
        guard document.episode(expectedIdentity.episodeID)?.episode.content == content,
              pendingDeviceSyncEditIntentMarker == nil,
              generationIsAcknowledged else {
            deviceSyncLocalDurabilityState = .pending
            return
        }
        deviceSyncLocalDurabilityState = .saved
    }

    func acknowledgeDeviceSyncPackageIntent(
        contentDigest: SyncContentDigest,
        identity: DeviceSyncEpisodeIdentity,
        throughSequence: UInt64?,
        runtime: DeviceSyncRuntime
    ) async throws -> Bool {
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: identity.documentSession)
        let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: identity.documentSession.documentID,
            episodeID: identity.episodeID
        )
        guard let checkpoint = snapshot.committedPackage,
              checkpoint.containsLocalEditIntent else { return true }
        guard let throughSequence,
              checkpoint.contentDigest == contentDigest,
              checkpoint.sequence <= throughSequence else { return false }
        let acknowledged = try await runtime.editIntentStore.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: identity.documentSession.documentID,
            episodeID: identity.episodeID,
            throughSequence: checkpoint.sequence,
            contentDigest: contentDigest
        )
        return acknowledged.committedPackage?.containsLocalEditIntent != true
    }

    private func removeAcknowledgedDeviceSyncMarkers(
        receipt: EpisodeLocalEditReceipt,
        content: String,
        identity: DeviceSyncEpisodeIdentity,
        mutationSequence: UInt64?,
        runtime: DeviceSyncRuntime
    ) async throws -> Bool {
        let scope = (
            workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: identity.documentSession),
            documentID: identity.documentSession.documentID,
            episodeID: identity.episodeID
        )
        let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: scope.workingCopyIdentity,
            documentID: scope.documentID,
            episodeID: scope.episodeID
        )
        guard deviceSyncContextIsCurrent(identity),
              document.episode(identity.episodeID)?.episode.content == content else { return false }
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
        expectedLookup: DeviceSyncLookupIdentity,
        baseContentDigest: SyncContentDigest? = nil,
        previousContentDigest: SyncContentDigest? = nil,
        resolvesPreservedSequences: [UInt64]? = nil
    ) {
        guard let runtime = deviceSyncRuntime else { return }
        registerDeviceSyncContentMutation(content, episodeID: expectedLookup.episodeID)
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

    private func runDeviceSyncEditIntentWorker(runtime: DeviceSyncRuntime) async {
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
                // Keep at most one retry payload in memory. A later edit wins,
                // but a failed in-flight body is retained when it is still the
                // newest mutation.
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
        identity: DeviceSyncEpisodeIdentity
    ) async -> Bool {
        await latestExactDeviceSyncEditIntentSequence(content: content, identity: identity) != nil
    }

    func latestExactDeviceSyncEditIntentSequence(
        content: String,
        identity: DeviceSyncEpisodeIdentity
    ) async -> UInt64? {
        guard let runtime = deviceSyncRuntime else { return nil }
        do {
            let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: identity.documentSession),
                documentID: identity.documentSession.documentID,
                episodeID: identity.episodeID
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
