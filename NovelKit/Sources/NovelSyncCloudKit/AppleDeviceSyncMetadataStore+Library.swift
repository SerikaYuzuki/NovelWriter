import NovelSync

extension AppleDeviceSyncMetadataStore {
    func replaceCachedLibraryEntries(
        _ entries: [SyncWorkLibraryEntry]
    ) throws {
        guard document.accountScope != nil else {
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        guard entries.count <= Self.maximumCachedLibraryEntryCount,
              Set(entries.map(\.workID)).count == entries.count,
              entries.allSatisfy({ $0.headRevisionID != nil }) else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        for entry in entries {
            try entry.validate()
        }
        var candidate = document
        candidate.cachedLibraryEntries = entries
        try commit(candidate)
    }

    func preparePendingLibraryOpen(
        _ entry: SyncWorkLibraryEntry
    ) throws -> ApplePendingLibraryOpenSnapshot {
        guard document.accountScope != nil else {
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        try entry.validate()
        guard entry.headRevisionID != nil else {
            throw AppleDeviceSyncServicesError.remoteWorkHasNoHead
        }
        if let index = document.pendingLibraryOpens.firstIndex(where: {
            $0.entry.workID == entry.workID
        }) {
            let existing = document.pendingLibraryOpens[index]
            guard existing.entry == entry else {
                throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
            }
            return pendingLibraryOpenSnapshot(from: existing)
        }
        guard document.pendingLibraryOpens.count < Self.maximumPendingLibraryOpenCount else {
            throw AppleDeviceSyncServicesError.metadataTooLarge
        }
        let locator = try AppleLocalDocumentLocator.cloudLibrary(workID: entry.workID)
        if let binding = document.bindings.first(where: { $0.locator == locator }) {
            guard binding.binding.workID == entry.workID else {
                throw AppleDeviceSyncServicesError.locatorAlreadyBound
            }
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        guard !document.pendingLibraryOpens.contains(where: { $0.locator == locator }) else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        let record = ApplePendingLibraryOpenRecord(
            token: AppleDeviceSyncPendingOpenToken(),
            locator: locator,
            entry: entry
        )
        var candidate = document
        candidate.pendingLibraryOpens.append(record)
        try commit(candidate)
        return pendingLibraryOpenSnapshot(from: record)
    }

    func pendingLibraryOpen(
        token: AppleDeviceSyncPendingOpenToken
    ) -> ApplePendingLibraryOpenSnapshot? {
        document.pendingLibraryOpens
            .first(where: { $0.token == token })
            .map(pendingLibraryOpenSnapshot)
    }

    func pendingLibraryOpen(
        workID: SyncWorkID
    ) -> ApplePendingLibraryOpenSnapshot? {
        document.pendingLibraryOpens
            .first(where: { $0.entry.workID == workID })
            .map(pendingLibraryOpenSnapshot)
    }

    func hasPendingLibraryOpen(for locator: AppleLocalDocumentLocator) -> Bool {
        document.pendingLibraryOpens.contains(where: { $0.locator == locator })
    }

    func completePendingLibraryOpen(
        _ intent: ApplePendingLibraryOpenSnapshot
    ) throws {
        guard let index = document.pendingLibraryOpens.firstIndex(where: {
            $0.token == intent.token
        }) else {
            return
        }
        let stored = pendingLibraryOpenSnapshot(from: document.pendingLibraryOpens[index])
        guard stored == intent,
              let binding = document.bindings.first(where: { $0.locator == intent.locator }),
              binding.binding.workID == intent.entry.workID else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        var candidate = document
        candidate.pendingLibraryOpens.remove(at: index)
        try commit(candidate)
    }

    func pendingLibraryOpenSnapshot(
        from record: ApplePendingLibraryOpenRecord
    ) -> ApplePendingLibraryOpenSnapshot {
        ApplePendingLibraryOpenSnapshot(
            token: record.token,
            locator: record.locator,
            entry: record.entry
        )
    }
}
