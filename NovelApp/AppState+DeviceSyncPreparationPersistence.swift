import Foundation
import NovelCore
import NovelSync

extension AppState {
    func recoverDeviceSyncPreparationContent(
        from marker: DeviceSyncEditIntentMarker,
        replacing previousContent: String,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient
    ) async -> DeviceSyncPreparationRecovery? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(identity),
                  document.episode(identity.episodeID)?.episode.content == previousContent,
                  beginDocumentTransition() else { return nil }
            defer { endDocumentTransition() }
            guard let committed = committedDeviceSyncContent(identity: identity) else { return nil }
            if committed != previousContent {
                return await persistCommittedDeviceSyncPreparationContent(
                    committed,
                    replacing: previousContent,
                    identity: identity,
                    client: client
                )
            }
            installDeviceSyncEpisodeContent(
                marker.content,
                chapterID: identity.chapterID,
                episodeID: identity.episodeID,
                advancesEditorGeneration: true
            )
            guard await saveCoordinator.saveNow(),
                  let updated = updatePreparedDeviceSyncIdentity(from: identity) else { return nil }
            return await DeviceSyncPreparationRecovery(
                content: marker.content,
                identity: updated,
                state: client.coordinator.state
            )
        }
    }

    private func committedDeviceSyncContent(identity: DeviceSyncEpisodeIdentity) -> String? {
        let committed: String
        switch captureCommittedTextForDeviceSync() {
        case let .captured(content):
            committed = content
        case .notActive:
            committed = document.episode(identity.episodeID)?.episode.content ?? ""
        case .compositionInProgress:
            return nil
        }
        guard document.episode(identity.episodeID)?.episode.content == committed else { return nil }
        return committed
    }

    private func persistCommittedDeviceSyncPreparationContent(
        _ content: String,
        replacing previousContent: String,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient
    ) async -> DeviceSyncPreparationRecovery? {
        guard let lookup = currentDeviceSyncLookupIdentity,
              lookup.documentSession == identity.documentSession,
              lookup.episodeID == identity.episodeID else { return nil }
        enqueueDeviceSyncEditIntent(
            content: content,
            expectedLookup: lookup,
            baseContentDigest: deviceSyncDurablePackageDigest(
                for: identity.episodeID,
                fallbackContent: previousContent
            ),
            previousContentDigest: SyncContentDigest(content: previousContent)
        )
        guard await flushPendingDeviceSyncEditIntents() else { return nil }
        saveCoordinator.markDirty()
        guard await saveCoordinator.saveNow(),
              let updated = updatePreparedDeviceSyncIdentity(from: identity) else { return nil }
        do {
            let receipt = try await client.coordinator.recordLocalEdit(
                content,
                createdAt: deviceSyncRuntime?.now() ?? Date()
            )
            let sequence = await latestExactDeviceSyncEditIntentSequence(
                content: content,
                identity: updated
            )
            await markDeviceSyncLocalEditSavedIfCurrent(
                receipt,
                content: content,
                expectedIdentity: updated,
                acknowledgedMutationSequence: sequence
            )
            guard deviceSyncLocalDurabilityState == .saved else { return nil }
            return DeviceSyncPreparationRecovery(content: content, identity: updated, state: receipt.state)
        } catch {
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
    }

    private func updatePreparedDeviceSyncIdentity(
        from previous: DeviceSyncEpisodeIdentity
    ) -> DeviceSyncEpisodeIdentity? {
        guard let lookup = currentDeviceSyncLookupIdentity,
              lookup.documentSession == previous.documentSession,
              lookup.chapterID == previous.chapterID,
              lookup.episodeID == previous.episodeID else { return nil }
        let updated = DeviceSyncEpisodeIdentity(
            documentSession: lookup.documentSession,
            chapterID: lookup.chapterID,
            episodeID: lookup.episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            structureDigest: lookup.structureDigest,
            localWorkingCopyID: previous.localWorkingCopyID,
            syncKey: previous.syncKey
        )
        activeDeviceSyncIdentity = updated
        resolvedDeviceSyncLookupIdentity = lookup
        return updated
    }

    func deviceSyncEditIntentMarker(
        content: String,
        expectedLookup: DeviceSyncLookupIdentity,
        baseContentDigest: SyncContentDigest?,
        previousContentDigest: SyncContentDigest?
    ) -> DeviceSyncEditIntentMarker {
        let boundIdentity = activeDeviceSyncIdentity.flatMap { identity in
            identity.documentSession == expectedLookup.documentSession
                && identity.episodeID == expectedLookup.episodeID
                ? identity
                : nil
        }
        let contentDigest = SyncContentDigest(content: content)
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: expectedLookup.documentSession)
        let acceptedPriorPackageDigests = deviceSyncAcceptedPriorPackageDigests(
            workingCopyIdentity: workingCopyIdentity,
            episodeID: expectedLookup.episodeID,
            contentDigest: contentDigest,
            baseContentDigest: baseContentDigest,
            previousContentDigest: previousContentDigest
        )
        deviceSyncEditIntentLineage = (
            workingCopyIdentity,
            expectedLookup.episodeID,
            contentDigest,
            acceptedPriorPackageDigests
        )
        return DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: workingCopyIdentity,
            documentID: expectedLookup.documentSession.documentID,
            episodeID: expectedLookup.episodeID,
            editorContentGeneration: expectedLookup.editorContentGeneration,
            mutationSequence: deviceSyncEditIntentGeneration,
            createdAt: deviceSyncRuntime?.now() ?? Date(),
            replicaID: deviceSyncRuntime?.replicaID ?? SyncReplicaID(),
            localWorkingCopyID: boundIdentity?.localWorkingCopyID,
            workID: boundIdentity?.syncKey.workID,
            baseContentDigest: baseContentDigest,
            acceptedPriorPackageDigests: acceptedPriorPackageDigests,
            content: content,
            contentDigest: contentDigest
        )
    }

    private func deviceSyncAcceptedPriorPackageDigests(
        workingCopyIdentity: String,
        episodeID: EpisodeID,
        contentDigest: SyncContentDigest,
        baseContentDigest: SyncContentDigest?,
        previousContentDigest: SyncContentDigest?
    ) -> [SyncContentDigest] {
        var accepted = baseContentDigest.map { [$0] } ?? []
        if let previousContentDigest {
            if let lineage = deviceSyncEditIntentLineage,
               lineage.workingCopyIdentity == workingCopyIdentity,
               lineage.episodeID == episodeID,
               lineage.contentDigest == previousContentDigest {
                accepted.append(contentsOf: lineage.acceptedPriorPackageDigests)
            }
            accepted.append(previousContentDigest)
        } else if let lineage = deviceSyncEditIntentLineage,
                  lineage.workingCopyIdentity == workingCopyIdentity,
                  lineage.episodeID == episodeID,
                  lineage.contentDigest == contentDigest {
            accepted.append(contentsOf: lineage.acceptedPriorPackageDigests)
        }
        var seen = Set<SyncContentDigest>()
        let unique = accepted.filter { seen.insert($0).inserted }
        guard unique.count > 4096 else { return unique }
        return [unique[0]] + unique.suffix(4095)
    }

    func deviceSyncWorkingCopyIdentity(for session: DocumentSessionToken) -> String {
        SyncContentDigest(
            content: "FUMINIWA-MAC-WORKING-COPY-V1\n\(session.documentURL.standardizedFileURL.path)"
        ).rawValue
    }
}
