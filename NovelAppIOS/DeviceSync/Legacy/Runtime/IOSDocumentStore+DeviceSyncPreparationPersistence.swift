import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    func recoverDeviceSyncPreparationContent(
        from marker: IOSDeviceSyncEditIntentMarker,
        replacing previousContent: String,
        identity: IOSDeviceSyncEpisodeIdentity,
        client: IOSDeviceSyncClient
    ) async -> IOSDeviceSyncPreparationRecovery? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(identity),
                  document.episode(identity.editingToken.episodeID)?.episode.content == previousContent,
                  beginDeviceSyncBoundaryTransition() else { return nil }
            defer { endDeviceSyncBoundaryTransition() }
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
                chapterID: identity.editingToken.chapterID,
                episodeID: identity.editingToken.episodeID,
                advancesEditorGeneration: true
            )
            guard await saveCoordinator.saveNow(),
                  let updated = updatePreparedDeviceSyncIdentity(from: identity) else { return nil }
            return await IOSDeviceSyncPreparationRecovery(
                content: marker.content,
                identity: updated,
                state: client.coordinator.state
            )
        }
    }

    private func committedDeviceSyncContent(identity: IOSDeviceSyncEpisodeIdentity) -> String? {
        let committed: String
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(content):
            committed = content
        case .notActive:
            committed = document.episode(identity.editingToken.episodeID)?.episode.content ?? ""
        case .compositionInProgress:
            return nil
        }
        guard document.episode(identity.editingToken.episodeID)?.episode.content == committed else { return nil }
        return committed
    }

    private func persistCommittedDeviceSyncPreparationContent(
        _ content: String,
        replacing previousContent: String,
        identity: IOSDeviceSyncEpisodeIdentity,
        client: IOSDeviceSyncClient
    ) async -> IOSDeviceSyncPreparationRecovery? {
        guard let lookup = currentDeviceSyncLookupIdentity,
              lookup.editingToken.documentSession == identity.editingToken.documentSession,
              lookup.editingToken.episodeID == identity.editingToken.episodeID else { return nil }
        enqueueDeviceSyncEditIntent(
            content: content,
            expectedLookup: lookup,
            baseContentDigest: deviceSyncDurablePackageDigest(
                for: identity.editingToken.episodeID,
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
            return IOSDeviceSyncPreparationRecovery(content: content, identity: updated, state: receipt.state)
        } catch {
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
    }

    private func updatePreparedDeviceSyncIdentity(
        from previous: IOSDeviceSyncEpisodeIdentity
    ) -> IOSDeviceSyncEpisodeIdentity? {
        guard let lookup = currentDeviceSyncLookupIdentity,
              lookup.editingToken.documentSession == previous.editingToken.documentSession,
              lookup.editingToken.chapterID == previous.editingToken.chapterID,
              lookup.editingToken.episodeID == previous.editingToken.episodeID else { return nil }
        let updated = IOSDeviceSyncEpisodeIdentity(
            editingToken: lookup.editingToken,
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
        expectedLookup: IOSDeviceSyncLookupIdentity,
        baseContentDigest: SyncContentDigest?,
        previousContentDigest: SyncContentDigest?
    ) -> IOSDeviceSyncEditIntentMarker {
        let boundIdentity = activeDeviceSyncIdentity.flatMap { identity in
            identity.editingToken == expectedLookup.editingToken ? identity : nil
        }
        let contentDigest = SyncContentDigest(content: content)
        let workingCopyIdentity = deviceSyncWorkingCopyIdentity(
            for: expectedLookup.editingToken.documentSession.workingCopyID
        )
        let acceptedPriorPackageDigests = deviceSyncAcceptedPriorPackageDigests(
            workingCopyIdentity: workingCopyIdentity,
            episodeID: expectedLookup.editingToken.episodeID,
            contentDigest: contentDigest,
            baseContentDigest: baseContentDigest,
            previousContentDigest: previousContentDigest
        )
        deviceSyncEditIntentLineage = (
            workingCopyIdentity,
            expectedLookup.editingToken.episodeID,
            contentDigest,
            acceptedPriorPackageDigests
        )
        return IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: workingCopyIdentity,
            documentID: document.id,
            episodeID: expectedLookup.editingToken.episodeID,
            editorContentGeneration: expectedLookup.editingToken.editorContentGeneration,
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

    func deviceSyncWorkingCopyIdentity(for workingCopyID: IOSPrivateDocumentID) -> String {
        SyncContentDigest(
            content: "FUMINIWA-IOS-WORKING-COPY-V1\n\(workingCopyID.packageName)"
        ).rawValue
    }
}
