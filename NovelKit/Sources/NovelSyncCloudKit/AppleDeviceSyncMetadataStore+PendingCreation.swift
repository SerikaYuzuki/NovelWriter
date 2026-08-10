import NovelCore
import NovelSync

extension AppleDeviceSyncMetadataStore {
    func containsBindingOrPendingWorkCreation(
        for locator: AppleLocalDocumentLocator
    ) -> Bool {
        document.bindings.contains(where: { $0.locator == locator })
            || document.pendingWorkCreations.contains(where: { $0.locator == locator })
    }

    /// remote createより先に永続化する。再試行時は同じlocatorとsource documentの
    /// 保存済みdescriptor／allowlistを正とし、途中のtitle／構造変更を混ぜない。
    func preparePendingWorkCreation(
        _ locator: AppleLocalDocumentLocator,
        proposedDescriptor: SyncWorkDescriptor,
        allowedEpisodeIDs: [EpisodeID]
    ) throws -> ApplePendingWorkCreationSnapshot {
        guard document.accountScope != nil else {
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        if let existing = document.pendingWorkCreations.first(where: { $0.locator == locator }) {
            return try resumePendingWorkCreation(
                existing,
                proposedDescriptor: proposedDescriptor
            )
        }
        let validatedEpisodeIDs = try validatedAllowedEpisodeIDs(allowedEpisodeIDs)
        guard proposedDescriptor.title.utf8.count
            <= CloudKitRecordCodec.maximumWorkTitleUTF8Bytes else {
            throw AppleDeviceSyncServicesError.metadataTooLarge
        }
        guard !document.bindings.contains(where: { $0.locator == locator }) else {
            throw AppleDeviceSyncServicesError.locatorAlreadyBound
        }
        guard document.pendingWorkCreations.count < Self.maximumPendingWorkCreationCount,
              !document.pendingWorkCreations.contains(where: {
                  $0.descriptor.workID == proposedDescriptor.workID
              }) else {
            throw AppleDeviceSyncServicesError.metadataTooLarge
        }
        let record = ApplePendingWorkCreationRecord(
            locator: locator,
            descriptor: proposedDescriptor,
            allowedEpisodeIDs: validatedEpisodeIDs
        )
        var candidate = document
        candidate.pendingWorkCreations.append(record)
        try commit(candidate)
        return pendingWorkCreationSnapshot(from: record)
    }

    /// bindが永続化され、descriptor／allowlistまで一致した後だけintentを消す。
    func completePendingWorkCreation(
        _ intent: ApplePendingWorkCreationSnapshot
    ) throws {
        if let existing = pendingWorkCreation(for: intent.locator), existing != intent {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        _ = try completePendingWorkCreationIfConfirmed(
            intent.locator,
            remoteDescriptor: intent.descriptor
        )
    }

    /// bind後clear前のkillを、通常のresolve経路から回収する。
    @discardableResult
    func completePendingWorkCreationIfConfirmed(
        _ locator: AppleLocalDocumentLocator,
        remoteDescriptor: SyncWorkDescriptor
    ) throws -> Bool {
        guard let index = document.pendingWorkCreations.firstIndex(where: {
            $0.locator == locator
        }) else { return false }
        let intent = pendingWorkCreationSnapshot(from: document.pendingWorkCreations[index])
        guard remoteDescriptor == intent.descriptor,
              let binding = document.bindings.first(where: { $0.locator == locator }),
              binding.binding.workID == intent.descriptor.workID,
              Set(binding.allowedEpisodeIDs) == intent.allowedEpisodeIDs else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        var candidate = document
        candidate.pendingWorkCreations.remove(at: index)
        try commit(candidate)
        return true
    }

    func pendingWorkCreation(
        for locator: AppleLocalDocumentLocator
    ) -> ApplePendingWorkCreationSnapshot? {
        document.pendingWorkCreations
            .first(where: { $0.locator == locator })
            .map(pendingWorkCreationSnapshot)
    }

    func pendingWorkCreationSnapshot(
        from record: ApplePendingWorkCreationRecord
    ) -> ApplePendingWorkCreationSnapshot {
        ApplePendingWorkCreationSnapshot(
            locator: record.locator,
            descriptor: record.descriptor,
            allowedEpisodeIDs: Set(record.allowedEpisodeIDs)
        )
    }

    private func resumePendingWorkCreation(
        _ existing: ApplePendingWorkCreationRecord,
        proposedDescriptor: SyncWorkDescriptor
    ) throws -> ApplePendingWorkCreationSnapshot {
        guard Self.matchesRetry(existing.descriptor, proposed: proposedDescriptor) else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        if let binding = document.bindings.first(where: { $0.locator == existing.locator }) {
            guard binding.binding.workID == existing.descriptor.workID,
                  binding.allowedEpisodeIDs == existing.allowedEpisodeIDs else {
                throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
            }
        }
        return pendingWorkCreationSnapshot(from: existing)
    }

    private static func matchesRetry(
        _ saved: SyncWorkDescriptor,
        proposed: SyncWorkDescriptor
    ) -> Bool {
        saved.sourceDocumentID == proposed.sourceDocumentID
    }
}
