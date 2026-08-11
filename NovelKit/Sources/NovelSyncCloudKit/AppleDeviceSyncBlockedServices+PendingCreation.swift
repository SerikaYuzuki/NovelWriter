import NovelCore
import NovelSync

public extension AppleDeviceSyncBlockedServices {
    /// Persists an account-scoped new/import identity while the previously
    /// verified account is only temporarily offline. This performs no zone or
    /// remote mutation and deliberately leaves the creation intent pending.
    @discardableResult
    func prepareAndBindPendingWorkCreation(
        _ locator: AppleLocalDocumentLocator,
        proposedDescriptor: SyncWorkDescriptor,
        allowedEpisodeIDs: [EpisodeID]
    ) async throws -> AppleLocalResolvedWorkingCopy {
        guard reason == .temporarilyUnavailable else {
            throw AppleDeviceSyncServicesError.blocked(reason)
        }
        let metadata = await metadataStore.snapshot()
        guard metadata.accountScope != nil else {
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        let canonicalLocator = try AppleLocalDocumentLocator.cloudLibrary(
            workID: proposedDescriptor.workID
        )
        guard locator == canonicalLocator else {
            throw AppleDeviceSyncServicesError.invalidLocator
        }

        let intent = try await metadataStore.preparePendingWorkCreation(
            locator,
            proposedDescriptor: proposedDescriptor,
            allowedEpisodeIDs: allowedEpisodeIDs
        )
        guard intent.locator == locator,
              intent.descriptor.workID == proposedDescriptor.workID else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        let binding = try await metadataStore.bind(
            intent.locator,
            to: intent.descriptor.workID,
            allowedEpisodeIDs: Array(intent.allowedEpisodeIDs)
        )
        guard let resolved = try await resolveLocal(intent.locator),
              resolved.binding == binding.binding,
              resolved.allowedEpisodeIDs == intent.allowedEpisodeIDs else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        return resolved
    }
}
