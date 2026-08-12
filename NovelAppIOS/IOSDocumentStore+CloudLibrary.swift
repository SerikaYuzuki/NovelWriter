import Foundation
import NovelCore
import NovelSync

enum IOSCloudLibraryConnection: Equatable, Sendable {
    case checking
    case available
    case offline
    case accountRequired
    case differentAccount
    case unavailable
}

enum IOSCloudLibraryAvailability: Equatable, Sendable {
    case cachedRemote
    case localPending
    case localOnly
    case accountQuarantined
    case legacyLocal
    case remoteOnly
    case remotePending
    case needsReview
    case cloudUnavailable
    case unavailable
}

struct IOSCloudLibraryItem: Identifiable, Equatable, Sendable {
    let id: SyncWorkID
    let title: String
    let updatedAt: Date?
    let availability: IOSCloudLibraryAvailability
    let isTitleTruncated: Bool

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "名称未設定の作品" : trimmed
        guard isTitleTruncated, !normalized.hasSuffix("…") else { return normalized }
        return normalized + "…"
    }
}

private struct IOSVerifiedCloudLibraryItem {
    let record: IOSDeviceSyncLocalLibraryRecord?
    let attestation: IOSDeviceSyncLocalPackageAttestation?
    let row: IOSCloudLibraryItem
}

private struct IOSVerifiedCloudLibrarySnapshot {
    let items: [SyncWorkID: IOSVerifiedCloudLibraryItem]

    var rows: [IOSCloudLibraryItem] {
        items.values.compactMap { item in
            guard item.record?.state != .legacyPreserved else { return nil }
            guard item.attestation != nil
                || item.record?.state != .remoteOpenPending else { return nil }
            return item.row
        }
    }
}

private enum IOSCloudLibraryOperationError: Error {
    case unavailable
    case staleSelection
    case packageMismatch
}

extension IOSDocumentStore {
    var usesCloudLibrary: Bool {
        deviceSyncRuntime?.library != nil
    }

    @discardableResult
    func refreshCloudLibrary() async -> Bool {
        guard !deviceSyncStartupFailedSafely,
              deviceSyncRuntime?.library != nil else { return false }
        if let cloudLibraryRefreshTask {
            return await cloudLibraryRefreshTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await performCloudLibraryRefresh()
        }
        cloudLibraryRefreshTask = task
        let result = await task.value
        cloudLibraryRefreshTask = nil
        return result
    }

    /// CloudKitを待たずに、検証済みの端末内working copyだけで棚を構築する。
    /// 起動時はこれを先に完了させ、remote catalogの確認は後段で行う。
    @discardableResult
    func refreshLocalCloudLibrary() async -> Bool {
        guard !deviceSyncStartupFailedSafely,
              let runtime = deviceSyncRuntime,
              let library = runtime.library else { return false }
        libraryRefreshGeneration &+= 1
        let generation = libraryRefreshGeneration

        let local: IOSVerifiedCloudLibrarySnapshot
        do {
            local = try await loadVerifiedCloudLibrary(using: library, now: runtime.now())
        } catch {
            guard generation == libraryRefreshGeneration else { return false }
            cloudLibraryItems = []
            cloudLibraryRemoteEntries = [:]
            cloudLibraryConnection = .unavailable
            cloudLibraryIsLoading = false
            permitsCloudLibraryMutation = false
            mayAttemptInitialCloudPublish = false
            operationErrorMessage = "この端末の作品情報を安全に確認できませんでした。"
            return false
        }

        guard generation == libraryRefreshGeneration else { return false }
        cloudLibraryItems = local.items.values.compactMap { item in
            guard item.record?.state != .remoteOpenPending else { return nil }
            return item.record?.state == .legacyPreserved ? nil : item.row
        }.sorted(by: Self.cloudLibraryItemComesBefore)
        cloudLibraryRemoteEntries = [:]
        cloudLibraryConnection = .checking
        cloudLibraryIsLoading = false
        permitsCloudLibraryMutation = false
        mayAttemptInitialCloudPublish = false
        return true
    }

    private func performCloudLibraryRefresh() async -> Bool {
        guard !deviceSyncStartupFailedSafely,
              let runtime = deviceSyncRuntime,
              let library = runtime.library else { return false }
        libraryRefreshGeneration &+= 1
        let generation = libraryRefreshGeneration
        // CloudKit refresh is a remote status lane. It must not replace the
        // visible shelf or disable local creation/import while transport is
        // suspended or reconnecting.
        cloudLibraryIsLoading = false

        let local: IOSVerifiedCloudLibrarySnapshot
        do {
            local = try await loadVerifiedCloudLibrary(using: library, now: runtime.now())
        } catch {
            guard generation == libraryRefreshGeneration else { return false }
            cloudLibraryItems = []
            cloudLibraryRemoteEntries = [:]
            cloudLibraryConnection = .unavailable
            cloudLibraryIsLoading = false
            operationErrorMessage = "この端末の作品情報を安全に確認できませんでした。"
            return false
        }

        guard generation == libraryRefreshGeneration else { return false }
        // Account scope確認前は、旧account由来のpending identity/titleを一瞬も公開しない。
        cloudLibraryItems = local.items.values.compactMap { item in
            guard item.record?.state != .remoteOpenPending else { return nil }
            return item.record?.state == .legacyPreserved ? nil : item.row
        }.sorted(by: Self.cloudLibraryItemComesBefore)
        permitsCloudLibraryMutation = true
        let resumable = await library.offlineResumableRemoteOpenWorkIDs()
        guard generation == libraryRefreshGeneration else { return false }

        do {
            var remote = try await library.loadRemoteLibrary()
            guard generation == libraryRefreshGeneration else { return false }
            guard generation == libraryRefreshGeneration else { return false }
            let activeWorkID = try await library.workIDForPackageURL(documentURL)
            let didRetry = await retryPendingCloudPublications(
                local: local,
                remote: remote,
                library: library,
                activeWorkID: activeWorkID
            )
            if didRetry {
                remote = try await library.loadRemoteLibrary()
                guard generation == libraryRefreshGeneration else { return false }
            }
            // local inventoryを検証できた後は、account未設定/切替中でも端末内に
            // local-only作品を作れる。`.checking`だけはscope判定前なので止める。
            permitsCloudLibraryMutation = remote.connection != .checking
            mayAttemptInitialCloudPublish = remote.connection == .available
                || remote.connection == .offline
            cloudLibraryConnection = Self.cloudConnection(remote.connection)
            cloudLibraryItems = await mergeCloudLibrary(
                local: local,
                remote: remote,
                resumableWorkIDs: resumable,
                library: library
            ).sorted(by: Self.cloudLibraryItemComesBefore)
            cloudLibraryIsLoading = false
            return true
        } catch {
            guard generation == libraryRefreshGeneration else { return false }
            // local inventoryは検証済み。remote catalog例外でもlocal-only作成/取込は
            // 保持し、uploadだけpublish authorityの検査で止める。
            permitsCloudLibraryMutation = true
            mayAttemptInitialCloudPublish = false
            cloudLibraryRemoteEntries = [:]
            cloudLibraryConnection = .unavailable
            // Account scopeを確認できない例外経路では、packageを持たない
            // pending-open identityを旧accountから復元・表示しない。
            cloudLibraryItems = local.items.values.compactMap { item in
                guard item.record?.state != .remoteOpenPending else {
                    guard item.attestation != nil else { return nil }
                    return IOSCloudLibraryItem(
                        id: item.row.id,
                        title: item.row.title,
                        updatedAt: item.row.updatedAt,
                        availability: .unavailable,
                        isTitleTruncated: item.row.isTitleTruncated
                    )
                }
                return item.record?.state == .legacyPreserved ? nil : item.row
            }.sorted(by: Self.cloudLibraryItemComesBefore)
            cloudLibraryIsLoading = false
            return true
        }
    }

    private func loadVerifiedCloudLibrary(
        using library: IOSDeviceSyncLibraryRuntime,
        now: Date
    ) async throws -> IOSVerifiedCloudLibrarySnapshot {
        let inventory = try await library.loadLocalInventory()
        var items: [SyncWorkID: IOSVerifiedCloudLibraryItem] = [:]
        for stored in inventory.records {
            let record = await repairReservedCloudWorkIfPossible(stored, library: library)
            items[record.workID] = await verifyCloudLibraryRecord(
                record,
                library: library,
                now: now
            )
        }
        for workID in inventory.unregisteredPackageWorkIDs.subtracting(items.keys) {
            items[workID] = await verifyLegacyCloudLibraryPackage(
                workID,
                library: library,
                now: now
            )
        }
        for workID in inventory.unreadableWorkIDs.subtracting(items.keys) {
            items[workID] = IOSVerifiedCloudLibraryItem(
                record: nil,
                attestation: nil,
                row: IOSCloudLibraryItem(
                    id: workID,
                    title: "確認が必要な作品",
                    updatedAt: nil,
                    availability: .unavailable,
                    isTitleTruncated: false
                )
            )
        }
        return IOSVerifiedCloudLibrarySnapshot(items: items)
    }

    private func verifyLegacyCloudLibraryPackage(
        _ workID: SyncWorkID,
        library: IOSDeviceSyncLibraryRuntime,
        now: Date
    ) async -> IOSVerifiedCloudLibraryItem {
        do {
            guard let portable = repository as? PortableDocumentPackageRepository else {
                throw IOSCloudLibraryOperationError.unavailable
            }
            try await library.validateInstalledPackage(workID)
            let url = try await library.packageURL(workID)
            let document = try await portable.validatePortablePackage(at: url)
            try await library.validateInstalledPackage(workID)
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let attestation = try IOSDeviceSyncLocalPackageAttestation(
                document: document,
                updatedAt: modifiedAt ?? now
            )
            return IOSVerifiedCloudLibraryItem(
                record: nil,
                attestation: attestation,
                row: IOSCloudLibraryItem(
                    id: workID,
                    title: attestation.titleProjection,
                    updatedAt: attestation.updatedAt,
                    availability: .legacyLocal,
                    isTitleTruncated: attestation.fullTitleUTF8ByteCount
                        > attestation.titleProjection.utf8.count
                )
            )
        } catch {
            return IOSVerifiedCloudLibraryItem(
                record: nil,
                attestation: nil,
                row: IOSCloudLibraryItem(
                    id: workID,
                    title: "確認が必要な作品",
                    updatedAt: nil,
                    availability: .unavailable,
                    isTitleTruncated: false
                )
            )
        }
    }

    private func repairReservedCloudWorkIfPossible(
        _ record: IOSDeviceSyncLocalLibraryRecord,
        library: IOSDeviceSyncLibraryRuntime
    ) async -> IOSDeviceSyncLocalLibraryRecord {
        guard record.state == .reservedForPublish,
              let expected = record.package,
              let portable = repository as? PortableDocumentPackageRepository else {
            return record
        }
        do {
            let finalURL = try await library.packageURL(record.workID)
            if await (try? library.validateInstalledPackage(record.workID)) == nil {
                let staging = try await library.stagingPackageURL(record.workID)
                try await library.validateStagingPackage(staging, record.workID)
                let staged = try await portable.validatePortablePackage(at: staging)
                let stagedAttestation = try IOSDeviceSyncLocalPackageAttestation(
                    document: staged,
                    updatedAt: expected.updatedAt
                )
                guard stagedAttestation == expected else { return record }
                let installed = try await library.installStagingPackage(staging, record.workID)
                guard installed == finalURL else { return record }
            }
            try await library.validateInstalledPackage(record.workID)
            let final = try await portable.validatePortablePackage(at: finalURL)
            let finalAttestation = try IOSDeviceSyncLocalPackageAttestation(
                document: final,
                updatedAt: expected.updatedAt
            )
            guard finalAttestation == expected else { return record }
            try await library.confirmPublishPackage(record.workID, expected)
            return IOSDeviceSyncLocalLibraryRecord(
                workID: record.workID,
                expectedDocumentID: record.expectedDocumentID,
                state: .publishPending,
                package: expected,
                acknowledgedRemote: nil,
                pendingRemote: nil
            )
        } catch {
            return record
        }
    }

    private func verifyCloudLibraryRecord(
        _ record: IOSDeviceSyncLocalLibraryRecord,
        library: IOSDeviceSyncLibraryRuntime,
        now _: Date
    ) async -> IOSVerifiedCloudLibraryItem {
        let canResume = record.state == .remoteOpenPending
            ? await library.canResumeRemoteOpenOffline(record.workID)
            : false
        let hasPublishAuthority = record.state == .publishPending
            ? await library.hasLocalPublishAuthority(record.workID, record.expectedDocumentID)
            : false
        guard let recordedPackage = record.package else {
            return IOSVerifiedCloudLibraryItem(
                record: record,
                attestation: nil,
                row: IOSCloudLibraryItem(
                    id: record.workID,
                    title: "ダウンロードを再開する作品",
                    updatedAt: record.pendingRemote?.headClientCreatedAt,
                    availability: record.state == .remoteOpenPending && canResume
                        ? .remotePending
                        : record.state == .remoteOpenPending ? .remoteOnly : .unavailable,
                    isTitleTruncated: record.pendingRemote?.isTitleTruncated ?? false
                )
            )
        }

        let loaded: (NovelDocument, IOSDeviceSyncLocalPackageAttestation)?
        do {
            try await library.validateInstalledPackage(record.workID)
            let url = try await library.packageURL(record.workID)
            guard let portable = repository as? PortableDocumentPackageRepository else {
                throw IOSCloudLibraryOperationError.unavailable
            }
            let document = try await portable.validatePortablePackage(at: url)
            try await library.validateInstalledPackage(record.workID)
            let attestation = try IOSDeviceSyncLocalPackageAttestation(
                document: document,
                updatedAt: recordedPackage.updatedAt
            )
            loaded = (document, attestation)
        } catch {
            loaded = nil
        }
        guard let (_, attestation) = loaded,
              attestation == recordedPackage,
              attestation.documentID == record.expectedDocumentID else {
            return IOSVerifiedCloudLibraryItem(
                record: record,
                attestation: nil,
                row: IOSCloudLibraryItem(
                    id: record.workID,
                    title: recordedPackage.titleProjection,
                    updatedAt: recordedPackage.updatedAt,
                    availability: .unavailable,
                    isTitleTruncated: recordedPackage.fullTitleUTF8ByteCount
                        > recordedPackage.titleProjection.utf8.count
                )
            )
        }

        let journalNeedsReview: Bool
        do {
            journalNeedsReview = try await library.localWorkNeedsReview(
                record.workID,
                record.expectedDocumentID
            )
        } catch {
            // journal/root/metadataを読めない状態を「review payloadあり」と偽装しない。
            // 実際のreviewを提示できないためfail-closedでopenを止める。
            return IOSVerifiedCloudLibraryItem(
                record: record,
                attestation: attestation,
                row: IOSCloudLibraryItem(
                    id: record.workID,
                    title: attestation.titleProjection,
                    updatedAt: attestation.updatedAt,
                    availability: .unavailable,
                    isTitleTruncated: attestation.fullTitleUTF8ByteCount
                        > attestation.titleProjection.utf8.count
                )
            )
        }

        let availability: IOSCloudLibraryAvailability = if journalNeedsReview {
            .needsReview
        } else {
            switch record.state {
            case .synced where record.acknowledgedRemote.map(attestation.matches) == true:
                .cachedRemote
            case .publishPending:
                hasPublishAuthority ? .localPending : .localOnly
            case .needsReview:
                .needsReview
            case .synced:
                .localPending
            case .remoteOpenPending:
                canResume ? .remotePending : .unavailable
            case .accountQuarantined:
                .accountQuarantined
            case .reservedForPublish, .legacyPreserved:
                .unavailable
            }
        }
        return IOSVerifiedCloudLibraryItem(
            record: record,
            attestation: attestation,
            row: IOSCloudLibraryItem(
                id: record.workID,
                title: attestation.titleProjection,
                updatedAt: attestation.updatedAt,
                availability: availability,
                isTitleTruncated: attestation.fullTitleUTF8ByteCount
                    > attestation.titleProjection.utf8.count
            )
        )
    }

    private func mergeCloudLibrary(
        local: IOSVerifiedCloudLibrarySnapshot,
        remote: IOSDeviceSyncRemoteLibrarySnapshot,
        resumableWorkIDs: [SyncWorkID],
        library: IOSDeviceSyncLibraryRuntime
    ) async -> [IOSCloudLibraryItem] {
        var rows = Dictionary(uniqueKeysWithValues: local.rows.map { ($0.id, $0) })
        var exactEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]

        if remote.connection == .checking {
            for (workID, item) in local.items where item.record?.state == .remoteOpenPending {
                rows.removeValue(forKey: workID)
            }
            cloudLibraryRemoteEntries = [:]
            return Array(rows.values)
        }

        if remote.connection == .accountRequired || remote.connection == .differentAccount {
            for (workID, item) in local.items
                where item.record?.state == .remoteOpenPending && item.attestation == nil {
                rows.removeValue(forKey: workID)
            }
            // App registryはaccount-independent。旧accountのackがpackageと一致しても、
            // current account scopeを証明できない間はcheckmark/upload authorityを出さない。
            for (workID, item) in local.items where item.attestation != nil {
                let availability = await accountScopedAvailability(
                    item,
                    workID: workID,
                    library: library
                )
                rows[workID] = IOSCloudLibraryItem(
                    id: workID,
                    title: item.row.title,
                    updatedAt: item.row.updatedAt,
                    availability: availability,
                    isTitleTruncated: item.row.isTitleTruncated
                )
            }
            cloudLibraryRemoteEntries = [:]
            return Array(rows.values)
        }

        if remote.connection == .offline {
            for (workID, item) in local.items {
                guard item.record?.state == .remoteOpenPending
                    || item.record?.state == .accountQuarantined,
                    let pending = item.record?.pendingRemote,
                    let attestation = item.attestation,
                    attestation.matches(pending) else { continue }
                let availability: IOSCloudLibraryAvailability
                if await library.hasCompletedRemoteOpenLocally(pending) {
                    do {
                        // bind完了→registry mark前のkill窓。account scopeをofflineとして
                        // 確認でき、exact pending/package/Domain journalが一致した時だけ復旧。
                        try await library.markSynced(workID, pending)
                        availability = .cachedRemote
                    } catch {
                        availability = .unavailable
                    }
                } else if item.record?.state == .accountQuarantined,
                          await library.canResumeRemoteOpenOffline(workID) {
                    do {
                        try await library.restoreRemoteOpenPending(workID, pending)
                        availability = .remotePending
                    } catch {
                        availability = .unavailable
                    }
                } else {
                    continue
                }
                rows[workID] = IOSCloudLibraryItem(
                    id: workID,
                    title: item.row.title,
                    updatedAt: item.row.updatedAt,
                    availability: availability,
                    isTitleTruncated: item.row.isTitleTruncated
                )
            }
        }

        for remoteItem in remote.entries {
            let entry = remoteItem.work
            if entry.headRevisionID != nil {
                exactEntries[entry.workID] = entry
            }
            if let localItem = local.items[entry.workID],
               let attestation = localItem.attestation {
                // 未登録の旧packageはremote identityと自動結合しない。利用者の明示
                // 取り込みで新WorkIDへ複製するまでrecovery rowのまま保つ。
                if localItem.record == nil {
                    continue
                }
                let availability: IOSCloudLibraryAvailability
                if localItem.row.availability == .unavailable {
                    // journal/root/metadata inspection failureなど、具体的なreview
                    // payloadを作れないfail-closed状態をremote projectionで上書きしない。
                    availability = .unavailable
                } else if localItem.row.availability == .needsReview {
                    availability = .needsReview
                } else if localItem.record?.state == .accountQuarantined,
                          localItem.record?.pendingRemote == entry,
                          attestation.matches(entry) {
                    do {
                        if await library.hasCompletedRemoteOpenLocally(entry) {
                            try await library.markSynced(entry.workID, entry)
                            availability = .cachedRemote
                        } else {
                            try await library.restoreRemoteOpenPending(entry.workID, entry)
                            availability = .remotePending
                        }
                    } catch {
                        availability = .unavailable
                    }
                } else if attestation.matches(entry),
                          remoteItem.availability == .locallyBound,
                          await library.hasCompletedRemoteOpenLocally(entry) {
                    do {
                        try await library.markSynced(entry.workID, entry)
                        availability = .cachedRemote
                    } catch {
                        availability = .unavailable
                    }
                } else if localItem.record?.state == .remoteOpenPending {
                    availability = localItem.row.availability
                } else if entry.headRevisionID == nil {
                    availability = localItem.record?.state == .accountQuarantined
                        ? .accountQuarantined
                        : .localPending
                } else if attestation.matches(entry) {
                    availability = remoteItem.availability == .locallyBound
                        && localItem.record?.acknowledgedRemote == entry
                        ? .cachedRemote
                        : .localPending
                } else {
                    availability = localItem.record?.state == .publishPending
                        ? .localPending
                        : localItem.record?.state == .accountQuarantined
                        ? .accountQuarantined
                        : .needsReview
                }
                rows[entry.workID] = IOSCloudLibraryItem(
                    id: entry.workID,
                    title: attestation.titleProjection,
                    updatedAt: attestation.updatedAt,
                    availability: availability,
                    isTitleTruncated: attestation.fullTitleUTF8ByteCount
                        > attestation.titleProjection.utf8.count
                )
            } else if local.items[entry.workID]?.record?.state == .remoteOpenPending,
                      local.items[entry.workID]?.attestation == nil,
                      remote.connection != .available {
                // package無しpendingはoffline catalog projectionだけでは公開しない。
                // exact revisionがDomainにあり、同一scopeのoffline connectionである
                // 場合だけ後段のgeneric resumable rowとして合流する。
                continue
            } else if entry.headRevisionID != nil,
                      rows[entry.workID]?.availability != .unavailable,
                      remote.connection != .accountRequired,
                      remote.connection != .differentAccount {
                let canResume = remoteItem.availability == .remoteDownloadPending
                    ? await library.canResumeRemoteOpenOffline(entry.workID)
                    : false
                rows[entry.workID] = IOSCloudLibraryItem(
                    id: entry.workID,
                    title: entry.title,
                    updatedAt: entry.headClientCreatedAt,
                    availability: canResume ? .remotePending : .remoteOnly,
                    isTitleTruncated: entry.isTitleTruncated
                )
            }
        }

        if remote.connection == .available {
            let listed = Set(remote.entries.map(\.work.workID))
            for (workID, localItem) in local.items
                where localItem.row.availability == .cachedRemote && !listed.contains(workID) {
                rows[workID] = IOSCloudLibraryItem(
                    id: workID,
                    title: localItem.row.title,
                    updatedAt: localItem.row.updatedAt,
                    availability: .cloudUnavailable,
                    isTitleTruncated: localItem.row.isTitleTruncated
                )
            }
        }
        cloudLibraryRemoteEntries = exactEntries
        return Self.addOfflineResumableRows(resumableWorkIDs, to: Array(rows.values))
    }

    private func accountScopedAvailability(
        _ item: IOSVerifiedCloudLibraryItem,
        workID: SyncWorkID,
        library: IOSDeviceSyncLibraryRuntime
    ) async -> IOSCloudLibraryAvailability {
        if item.record?.state == .remoteOpenPending, let attestation = item.attestation {
            do {
                try await library.quarantineForAccount(workID, attestation)
                return .accountQuarantined
            } catch {
                return .unavailable
            }
        }
        return switch item.row.availability {
        case .needsReview:
            .needsReview
        case .unavailable:
            .unavailable
        case .legacyLocal:
            .legacyLocal
        case .localOnly:
            .localOnly
        case .cachedRemote, .localPending, .accountQuarantined,
             .remoteOnly, .remotePending, .cloudUnavailable:
            .accountQuarantined
        }
    }

    private func retryPendingCloudPublications(
        local: IOSVerifiedCloudLibrarySnapshot,
        remote: IOSDeviceSyncRemoteLibrarySnapshot,
        library: IOSDeviceSyncLibraryRuntime,
        activeWorkID: SyncWorkID?
    ) async -> Bool {
        guard remote.connection == .available,
              let portable = repository as? PortableDocumentPackageRepository else { return false }
        var didPublish = false
        for item in local.items.values {
            guard item.row.availability == .localPending,
                  let record = item.record,
                  record.state == .publishPending,
                  let expected = item.attestation,
                  await library.hasLocalPublishAuthority(
                      record.workID,
                      record.expectedDocumentID
                  ) else { continue }
            do {
                if let remoteItem = remote.entries.first(where: {
                    $0.work.workID == record.workID
                }),
                    remoteItem.availability == .locallyBound,
                    expected.matches(remoteItem.work),
                    await library.hasCompletedRemoteOpenLocally(remoteItem.work) {
                    // Initial publish完了→App registry acknowledgement前の窓は、
                    // exact remote/domain proofをmerge側でmarkSyncedする。ここで
                    // 同じrevisionをhidden coordinatorへ二重送信しない。
                    continue
                }
                try await library.validateInstalledPackage(record.workID)
                let url = try await library.packageURL(record.workID)
                let document = try await portable.validatePortablePackage(at: url)
                let readback = try IOSDeviceSyncLocalPackageAttestation(
                    document: document,
                    updatedAt: expected.updatedAt
                )
                guard readback == expected, document.id == record.expectedDocumentID else { continue }
                if activeWorkID == record.workID {
                    try await library.publishNewWork(record.workID, document, url)
                } else {
                    try await library.resumeInitialWorkPublication(record.workID, document, url)
                }
                didPublish = true
            } catch {
                continue
            }
        }
        return didPublish
    }

    func retryPendingCloudPublicationsInBackground() async {
        guard usesCloudLibrary else { return }
        if let pendingCloudLibraryRetryTask {
            await pendingCloudLibraryRetryTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await refreshCloudLibrary()
        }
        pendingCloudLibraryRetryTask = task
        await task.value
        pendingCloudLibraryRetryTask = nil
    }

    @discardableResult
    func openCloudLibraryWork(_ workID: SyncWorkID) async -> Bool {
        guard let item = cloudLibraryItems.first(where: { $0.id == workID }),
              !cloudLibraryOperationInProgress else { return false }
        if item.availability == .legacyLocal {
            cloudLibraryOperationInProgress = true
            defer { cloudLibraryOperationInProgress = false }
            return await importLegacyPrivateWork(workID, expected: item)
        }
        cloudLibraryOperationInProgress = true
        defer { cloudLibraryOperationInProgress = false }

        if activeCloudWorkID == workID, startupState == .ready {
            return true
        }
        let opened: Bool
        switch item.availability {
        case .cachedRemote, .localPending, .localOnly, .accountQuarantined, .needsReview:
            opened = await openVerifiedCloudLibraryWork(workID, expected: item)
        case .remoteOnly where cloudLibraryConnection == .available:
            guard let entry = cloudLibraryRemoteEntries[workID] else { return false }
            opened = await materializeCloudLibraryWork(
                workID,
                expectedCatalogEntry: entry,
                expected: item
            )
        case .remotePending
            where cloudLibraryConnection == .available || cloudLibraryConnection == .offline:
            opened = await materializeCloudLibraryWork(
                workID,
                expectedCatalogEntry: nil,
                expected: item
            )
        case .remoteOnly, .remotePending, .legacyLocal, .cloudUnavailable, .unavailable:
            return false
        }
        if opened {
            await refreshOrPrepareSelectedEpisodeDeviceSync()
        } else {
            _ = await refreshCloudLibrary()
        }
        return opened
    }

    private func openVerifiedCloudLibraryWork(
        _ workID: SyncWorkID,
        expected: IOSCloudLibraryItem
    ) async -> Bool {
        guard let library = deviceSyncRuntime?.library else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  cloudLibraryItems.contains(expected) else { return false }
            return await performDocumentTransition {
                let inventory = try await library.loadLocalInventory()
                guard let record = inventory.records.first(where: { $0.workID == workID }),
                      let recorded = record.package else {
                    throw IOSCloudLibraryOperationError.staleSelection
                }
                try await library.validateInstalledPackage(workID)
                let url = try await library.packageURL(workID)
                guard let portable = repository as? PortableDocumentPackageRepository else {
                    throw IOSCloudLibraryOperationError.unavailable
                }
                let loaded = try await portable.validatePortablePackage(at: url)
                let attestation = try IOSDeviceSyncLocalPackageAttestation(
                    document: loaded,
                    updatedAt: recorded.updatedAt
                )
                guard attestation == recorded,
                      attestation.documentID == record.expectedDocumentID else {
                    throw IOSCloudLibraryOperationError.packageMismatch
                }
                switch expected.availability {
                case .cachedRemote:
                    guard record.state == .synced,
                          record.acknowledgedRemote.map(attestation.matches) == true else {
                        throw IOSCloudLibraryOperationError.staleSelection
                    }
                case .localPending:
                    guard record.state == .publishPending || record.state == .synced else {
                        throw IOSCloudLibraryOperationError.staleSelection
                    }
                case .localOnly:
                    guard record.state == .publishPending,
                          await library.hasLocalPublishAuthority(
                              workID,
                              record.expectedDocumentID
                          ) == false else {
                        throw IOSCloudLibraryOperationError.staleSelection
                    }
                case .accountQuarantined:
                    let isAccountMismatchProjection = (
                        cloudLibraryConnection == .accountRequired
                            || cloudLibraryConnection == .differentAccount
                    ) && (record.state == .synced || record.state == .publishPending)
                    guard record.state == .accountQuarantined
                        || isAccountMismatchProjection else {
                        throw IOSCloudLibraryOperationError.staleSelection
                    }
                case .needsReview:
                    if record.state != .needsReview, record.state != .synced {
                        guard try await library.localWorkNeedsReview(
                            workID,
                            record.expectedDocumentID
                        ) else {
                            throw IOSCloudLibraryOperationError.staleSelection
                        }
                    }
                case .legacyLocal, .remoteOnly, .remotePending, .cloudUnavailable, .unavailable:
                    throw IOSCloudLibraryOperationError.staleSelection
                }
                let loadedAttachments = try await loadAttachmentsForInstall(at: url)
                guard install(loaded, at: url, attachments: loadedAttachments) else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                activeCloudWorkID = workID
                startupState = .ready
                saveState = .saved
            }
        }
    }

    private func materializeCloudLibraryWork(
        _ workID: SyncWorkID,
        expectedCatalogEntry: SyncWorkLibraryEntry?,
        expected: IOSCloudLibraryItem
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  cloudLibraryItems.contains(expected),
                  expectedCatalogEntry == nil
                  || cloudLibraryRemoteEntries[workID] == expectedCatalogEntry else { return false }
            return await performDocumentTransition {
                guard let portable = repository as? PortableDocumentPackageRepository else {
                    throw IOSCloudLibraryOperationError.unavailable
                }
                let inventory = try await library.loadLocalInventory()
                let pending = inventory.records.first {
                    $0.workID == workID && $0.state == .remoteOpenPending
                }
                let prepared: IOSDeviceSyncPreparedLibraryWork
                if let pending, let pendingEntry = pending.pendingRemote {
                    prepared = try await library.resumeRemoteOpen(workID)
                    guard prepared.entry == pendingEntry else {
                        throw IOSCloudLibraryOperationError.packageMismatch
                    }
                } else if let expectedCatalogEntry {
                    prepared = try await library.prepareRemoteOpen(expectedCatalogEntry)
                    guard prepared.entry == expectedCatalogEntry else {
                        throw IOSCloudLibraryOperationError.packageMismatch
                    }
                    try await library.beginRemoteOpen(prepared.entry)
                } else {
                    prepared = try await library.resumeRemoteOpen(workID)
                    try await library.beginRemoteOpen(prepared.entry)
                }
                guard prepared.entry.workID == workID,
                      try prepared.packageSnapshot == WorkSnapshot(document: prepared.document) else {
                    throw IOSCloudLibraryOperationError.packageMismatch
                }

                let finalURL = try await library.packageURL(workID)
                let finalDocument: NovelDocument
                if await (try? library.validateInstalledPackage(workID)) != nil {
                    let existing = try await portable.validatePortablePackage(at: finalURL)
                    guard try WorkSnapshot(document: existing) == prepared.packageSnapshot else {
                        let attestation = try IOSDeviceSyncLocalPackageAttestation(
                            document: existing,
                            updatedAt: runtime.now()
                        )
                        try await library.quarantineInstalledPackage(workID, attestation)
                        throw IOSCloudLibraryOperationError.packageMismatch
                    }
                    finalDocument = existing
                } else {
                    let staging = try await library.stagingPackageURL(workID)
                    do {
                        try await repository.save(prepared.document, to: staging)
                        try await library.validateStagingPackage(staging, workID)
                        let staged = try await portable.validatePortablePackage(at: staging)
                        guard try WorkSnapshot(document: staged) == prepared.packageSnapshot else {
                            throw IOSCloudLibraryOperationError.packageMismatch
                        }
                        let installed = try await library.installStagingPackage(staging, workID)
                        guard installed == finalURL else {
                            throw IOSCloudLibraryOperationError.packageMismatch
                        }
                    } catch {
                        try? await library.discardStagingPackage(staging, workID)
                        throw error
                    }
                    try await library.validateInstalledPackage(workID)
                    finalDocument = try await portable.validatePortablePackage(at: finalURL)
                    guard try WorkSnapshot(document: finalDocument) == prepared.packageSnapshot else {
                        throw IOSCloudLibraryOperationError.packageMismatch
                    }
                }

                let attestation = try IOSDeviceSyncLocalPackageAttestation(
                    document: finalDocument,
                    updatedAt: runtime.now()
                )
                try await library.attestRemotePackage(
                    workID,
                    attestation,
                    prepared.entry
                )
                try await prepared.bind(prepared.packageSnapshot)
                try await library.markSynced(workID, prepared.entry)
                let loadedAttachments = try await loadAttachmentsForInstall(at: finalURL)
                guard install(finalDocument, at: finalURL, attachments: loadedAttachments) else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                activeCloudWorkID = workID
                startupState = .ready
                saveState = .saved
            }
        }
    }

    @discardableResult
    func makeNewCloudLibraryDocument() async -> Bool {
        guard await waitForCloudLibraryMutationReadinessIfChecking() else { return false }
        return await createCloudLibraryDocument(document: NovelDocument.newDocument(), sourceURL: nil)
    }

    @discardableResult
    func importCloudLibraryPackage(from sourceURL: URL) async -> Bool {
        guard await waitForCloudLibraryMutationReadinessIfChecking() else { return false }
        guard let portable = repository as? PortableDocumentPackageRepository else { return false }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let document = try await portable.validatePortablePackage(at: sourceURL)
            return await createCloudLibraryDocument(document: document, sourceURL: sourceURL)
        } catch {
            operationErrorMessage = "作品を取り込めませんでした。原本は変更していません。"
            return false
        }
    }

    private func waitForCloudLibraryMutationReadinessIfChecking() async -> Bool {
        guard usesCloudLibrary else { return true }
        if permitsCloudLibraryMutation {
            return true
        }
        guard cloudLibraryConnection == .checking else {
            operationErrorMessage = "この端末に作品を保存する準備ができませんでした。iCloud設定を確認して、もう一度お試しください。"
            return false
        }
        for _ in 0 ..< 200 {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return false }
            _ = await refreshCloudLibrary()
            if permitsCloudLibraryMutation {
                return true
            }
            if cloudLibraryConnection != .checking {
                break
            }
        }
        operationErrorMessage = "iCloudの確認が終わりませんでした。元の作品は変更していません。しばらくしてから、もう一度お試しください。"
        return false
    }

    /// D-063より前のhidden Works packageを自動でremote identityへ結び付けず、
    /// 利用者が行を選んだ時だけ新WorkIDへportable copyする。旧bytesは削除しない。
    private func importLegacyPrivateWork(
        _ legacyWorkID: SyncWorkID,
        expected: IOSCloudLibraryItem
    ) async -> Bool {
        guard expected.availability == .legacyLocal,
              cloudLibraryItems.contains(expected),
              let runtime = deviceSyncRuntime,
              let library = runtime.library,
              let portable = repository as? PortableDocumentPackageRepository else { return false }
        do {
            try await library.validateInstalledPackage(legacyWorkID)
            let sourceURL = try await library.packageURL(legacyWorkID)
            let sourceModifiedAt = try sourceURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard sourceModifiedAt == expected.updatedAt else {
                throw IOSCloudLibraryOperationError.staleSelection
            }
            let document = try await portable.validatePortablePackage(at: sourceURL)
            try await library.validateInstalledPackage(legacyWorkID)
            let sourceAttestation = try IOSDeviceSyncLocalPackageAttestation(
                document: document,
                updatedAt: sourceModifiedAt ?? runtime.now()
            )
            guard sourceAttestation.titleProjection == expected.title,
                  (sourceAttestation.fullTitleUTF8ByteCount
                      > sourceAttestation.titleProjection.utf8.count)
                  == expected.isTitleTruncated else {
                throw IOSCloudLibraryOperationError.packageMismatch
            }
            guard await createCloudLibraryDocument(
                document: document,
                sourceURL: sourceURL,
                operationAlreadyClaimed: true
            ) else {
                return false
            }
            // 新copyが完全readbackされてactiveになった後だけ旧packageを取り込み済みと
            // 記録する。旧package自体は保全し、失敗時は次回も復旧行へ残す。
            try await library.markLegacyPackageRecovered(legacyWorkID, sourceAttestation)
            _ = await refreshCloudLibrary()
            return true
        } catch {
            operationErrorMessage = "この端末の旧作品を取り込めませんでした。元の作品は変更していません。"
            _ = await refreshCloudLibrary()
            return false
        }
    }

    private func createCloudLibraryDocument(
        document newDocument: NovelDocument,
        sourceURL: URL?,
        operationAlreadyClaimed: Bool = false
    ) async -> Bool {
        let hasValidOperationClaim = operationAlreadyClaimed
            ? cloudLibraryOperationInProgress
            : !cloudLibraryOperationInProgress
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              let portable = repository as? PortableDocumentPackageRepository,
              permitsCloudLibraryMutation,
              hasValidOperationClaim else { return false }
        if !operationAlreadyClaimed {
            cloudLibraryOperationInProgress = true
        }
        defer {
            if !operationAlreadyClaimed {
                cloudLibraryOperationInProgress = false
            }
        }
        let workID = SyncWorkID()
        let shouldAttemptInitialCloudPublish = mayAttemptInitialCloudPublish
        let expected: IOSDeviceSyncLocalPackageAttestation
        do {
            expected = try IOSDeviceSyncLocalPackageAttestation(
                document: newDocument,
                updatedAt: runtime.now()
            )
        } catch {
            return false
        }

        let transitioned = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            return await performDocumentTransition {
                var stagingURL: URL?
                var installed = false
                try await library.reserveForPublish(workID, expected)
                do {
                    let staging = try await library.stagingPackageURL(workID)
                    stagingURL = staging
                    if let sourceURL {
                        try await portable.saveValidatedCopy(
                            newDocument,
                            from: sourceURL,
                            to: staging
                        )
                    } else {
                        try await repository.save(newDocument, to: staging)
                    }
                    try await library.validateStagingPackage(staging, workID)
                    let staged = try await portable.validatePortablePackage(at: staging)
                    let stagedAttestation = try IOSDeviceSyncLocalPackageAttestation(
                        document: staged,
                        updatedAt: expected.updatedAt
                    )
                    guard stagedAttestation == expected else {
                        throw IOSCloudLibraryOperationError.packageMismatch
                    }
                    let finalURL = try await library.installStagingPackage(staging, workID)
                    stagingURL = nil
                    installed = true
                    try await library.validateInstalledPackage(workID)
                    let finalReadback = try await portable.validatePortablePackage(at: finalURL)
                    let finalAttestation = try IOSDeviceSyncLocalPackageAttestation(
                        document: finalReadback,
                        updatedAt: expected.updatedAt
                    )
                    guard finalReadback == newDocument,
                          try WorkSnapshot(document: finalReadback)
                          == WorkSnapshot(document: newDocument),
                          finalAttestation == expected else {
                        throw IOSCloudLibraryOperationError.packageMismatch
                    }
                    try await library.confirmPublishPackage(workID, expected)
                    let loadedAttachments = try await loadAttachmentsForInstall(at: finalURL)
                    guard install(finalReadback, at: finalURL, attachments: loadedAttachments) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    activeCloudWorkID = workID
                    startupState = .ready
                    saveState = .saved
                    // Remote failure is not a local creation failure. The durable
                    // publishPending row is retried on refresh/foreground.
                    if shouldAttemptInitialCloudPublish {
                        try? await library.publishNewWork(workID, finalReadback, finalURL)
                    }
                } catch {
                    if let stagingURL {
                        try? await library.discardStagingPackage(stagingURL, workID)
                    }
                    if !installed {
                        try? await library.abortPublishReservation(workID)
                    }
                    throw error
                }
            }
        }
        _ = await refreshCloudLibrary()
        if transitioned {
            await refreshOrPrepareSelectedEpisodeDeviceSync()
        }
        return transitioned
    }

    func recordCloudLibraryPackageMutationIfNeeded(
        _ savedDocument: NovelDocument,
        at url: URL
    ) async throws {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              let workID = try await library.workIDForPackageURL(url) else { return }
        guard let portable = repository as? PortableDocumentPackageRepository else {
            throw IOSCloudLibraryOperationError.unavailable
        }
        let inventory = try await library.loadLocalInventory()
        guard let record = inventory.records.first(where: { $0.workID == workID }),
              record.state != .reservedForPublish,
              record.state != .legacyPreserved else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        try await library.validateInstalledPackage(workID)
        let canonicalURL = try await library.packageURL(workID)
        guard canonicalURL.standardizedFileURL == url.standardizedFileURL else {
            throw IOSCloudLibraryOperationError.packageMismatch
        }
        let readback = try await portable.validatePortablePackage(at: canonicalURL)
        try await library.validateInstalledPackage(workID)
        guard readback == savedDocument,
              try WorkSnapshot(document: readback) == WorkSnapshot(document: savedDocument) else {
            throw IOSCloudLibraryOperationError.packageMismatch
        }
        let attestation = try IOSDeviceSyncLocalPackageAttestation(
            document: readback,
            updatedAt: runtime.now()
        )
        try await library.recordPackageMutation(workID, attestation)
    }

    private static func cloudConnection(
        _ connection: IOSDeviceSyncLibraryConnection
    ) -> IOSCloudLibraryConnection {
        switch connection {
        case .checking: .checking
        case .available: .available
        case .offline: .offline
        case .accountRequired: .accountRequired
        case .differentAccount: .differentAccount
        }
    }

    private static func addOfflineResumableRows(
        _ workIDs: [SyncWorkID],
        to existing: [IOSCloudLibraryItem]
    ) -> [IOSCloudLibraryItem] {
        var rows = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for workID in workIDs where rows[workID] == nil {
            rows[workID] = IOSCloudLibraryItem(
                id: workID,
                title: "ダウンロードを再開する作品",
                updatedAt: nil,
                availability: .remotePending,
                isTitleTruncated: false
            )
        }
        return Array(rows.values)
    }

    private static func cloudLibraryItemComesBefore(
        _ lhs: IOSCloudLibraryItem,
        _ rhs: IOSCloudLibraryItem
    ) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let order = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            return order == .orderedSame
                ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                : order == .orderedAscending
        }
    }
}
