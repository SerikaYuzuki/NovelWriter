import NovelSync

extension IOSDocumentStore {
    func reconcileDeviceSyncPackageContentIfNeeded(
        state: EpisodeSyncState,
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async throws -> EpisodeSyncState {
        guard deviceSyncContextIsCurrent(identity),
              ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime),
              let context = deviceSyncWritableContext(from: state) else { return state }

        let episodeID = identity.editingToken.episodeID
        let packageContent = document.episode(episodeID)?.episode.content ?? ""
        let packageDigest = SyncContentDigest(content: packageContent)
        var reconciled = state
        var needsSynchronization = false
        if context.localHead.contentDigest != packageDigest {
            reconciled = try await client.coordinator.recordLocalContent(
                packageContent,
                createdAt: runtime.now()
            )
            needsSynchronization = true
        }
        switch reconciled {
        case .localChanges, .offlineFork:
            needsSynchronization = true
        default:
            break
        }
        guard needsSynchronization,
              deviceSyncContextIsCurrent(identity),
              ownsDeviceSyncAuthority(in: reconciled, client: client, runtime: runtime) else {
            return reconciled
        }
        let first = try await client.coordinator.synchronize()
        guard deviceSyncContextIsCurrent(identity),
              ownsDeviceSyncAuthority(in: first, client: client, runtime: runtime),
              case .localChanges = first else { return first }
        return try await client.coordinator.synchronize()
    }
}

private func deviceSyncWritableContext(from state: EpisodeSyncState) -> EpisodeSyncContext? {
    switch state {
    case let .upToDate(context), let .localChanges(context), let .offlineFork(context):
        context
    default:
        nil
    }
}
