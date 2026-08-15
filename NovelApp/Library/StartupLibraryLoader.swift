import Foundation
import NovelCore
import NovelSync

private struct StartupLibraryAvailabilityContext {
    let canResumeRemoteOpen: Bool
    let hasPublishAuthority: Bool
    let journalNeedsReview: Bool
}

/// app-private inventoryを読み、package readbackとregistry stateを検証するloader。
///
/// 棚の表示projectionやAppStateのsession commitは所有せず、I/Oの結果だけを値型で返す。
struct StartupLibraryLoader {
    let repository: DocumentRepository

    func loadVerifiedLocalLibrary(
        using library: DeviceSyncLibraryRuntime,
        now: Date
    ) async throws -> StartupVerifiedLocalLibrarySnapshot {
        let inventory = try await library.loadLocalInventory()
        var items: [SyncWorkID: StartupVerifiedLocalLibraryItem] = [:]

        for storedRecord in inventory.records {
            let record = await repairReservedLibraryWorkIfPossible(
                storedRecord,
                library: library
            )
            items[record.workID] = await verifyLocalLibraryRecord(
                record,
                library: library,
                now: now
            )
        }
        let isolated = inventory.unreadableWorkIDs
            .union(inventory.unregisteredPackageWorkIDs)
            .subtracting(items.keys)
        for workID in isolated {
            let title = await localLibraryPackageTitle(
                workID: workID,
                library: library,
                now: now
            )
            items[workID] = StartupVerifiedLocalLibraryItem(
                record: nil,
                attestation: title.attestation,
                row: StartupLibraryWork(
                    reference: .cloudWork(workID.rawValue),
                    title: title.attestation?.titleProjection ?? "確認が必要な作品",
                    updatedAt: title.attestation?.updatedAt,
                    availability: .unavailable,
                    isTitleTruncated: title.attestation.map {
                        $0.fullTitleUTF8ByteCount > $0.titleProjection.utf8.count
                    } ?? false
                )
            )
        }
        return StartupVerifiedLocalLibrarySnapshot(items: items)
    }

    /// staging attestation→RENAME_EXCL→confirmの各kill窓を、同じexact packageだけで
    /// 再開する。証明できないpackage/stagingは触らずdisabled行に残す。
    private func repairReservedLibraryWorkIfPossible(
        _ record: DeviceSyncLocalLibraryRecord,
        library: DeviceSyncLibraryRuntime
    ) async -> DeviceSyncLocalLibraryRecord {
        guard record.state == .reservedForPublish,
              let portableRepository = repository as? PortableDocumentPackageRepository else {
            return record
        }
        do {
            // D-063 より前の作成途中レコードは期待した作品内容を証明できない。
            // 同じ document ID だけで staging を採用せず、保全対象として隔離する。
            guard let attestation = record.package else { return record }

            let finalURL = try await library.packageURL(record.workID)
            if await (try? library.validateInstalledPackage(record.workID)) == nil {
                let staging = try await library.stagingPackageURL(record.workID)
                try await library.validateStagingPackage(staging, record.workID)
                let staged = try await portableRepository.validatePortablePackage(at: staging)
                let stagedAttestation = try DeviceSyncLocalPackageAttestation(
                    document: staged,
                    updatedAt: attestation.updatedAt
                )
                guard stagedAttestation == attestation else { return record }
                let installed = try await library.installStagingPackage(staging, record.workID)
                guard installed == finalURL else { return record }
            }

            try await library.validateInstalledPackage(record.workID)
            let final = try await portableRepository.validatePortablePackage(at: finalURL)
            let finalAttestation = try DeviceSyncLocalPackageAttestation(
                document: final,
                updatedAt: attestation.updatedAt
            )
            guard finalAttestation == attestation else { return record }
            try await library.confirmPublishPackage(record.workID, attestation)
            return DeviceSyncLocalLibraryRecord(
                workID: record.workID,
                expectedDocumentID: record.expectedDocumentID,
                state: .publishPending,
                package: attestation,
                acknowledgedRemote: nil,
                pendingRemote: nil
            )
        } catch {
            return record
        }
    }

    private func verifyLocalLibraryRecord(
        _ record: DeviceSyncLocalLibraryRecord,
        library: DeviceSyncLibraryRuntime,
        now: Date
    ) async -> StartupVerifiedLocalLibraryItem {
        let canResumeRemoteOpen = if record.state == .remoteOpenPending {
            await library.canResumeRemoteOpenOffline(record.workID)
        } else {
            false
        }
        let hasPublishAuthority = if record.state == .publishPending {
            await library.hasLocalPublishAuthority(record.workID, record.expectedDocumentID)
        } else {
            false
        }
        guard record.package != nil else {
            return unverifiedRow(for: record, canResumeRemoteOpen: canResumeRemoteOpen)
        }
        let verified = await localLibraryPackageTitle(
            workID: record.workID,
            library: library,
            now: record.package?.updatedAt ?? now
        )
        guard let attestation = verified.attestation,
              attestation.documentID == record.expectedDocumentID else {
            return invalidPackageRow(for: record)
        }

        guard let journalNeedsReview = try? await library.localWorkNeedsReview(
            record.workID,
            record.expectedDocumentID
        ) else {
            return unavailableRow(for: record, attestation: attestation)
        }
        let availability = await resolveAvailability(
            for: record,
            attestation: attestation,
            library: library,
            context: StartupLibraryAvailabilityContext(
                canResumeRemoteOpen: canResumeRemoteOpen,
                hasPublishAuthority: hasPublishAuthority,
                journalNeedsReview: journalNeedsReview
            )
        )
        return StartupVerifiedLocalLibraryItem(
            record: record,
            attestation: attestation,
            row: StartupLibraryWork(
                reference: .cloudWork(record.workID.rawValue),
                title: attestation.titleProjection,
                updatedAt: attestation.updatedAt,
                availability: availability,
                isTitleTruncated: attestation.fullTitleUTF8ByteCount > attestation.titleProjection.utf8.count
            )
        )
    }

    private func unverifiedRow(
        for record: DeviceSyncLocalLibraryRecord,
        canResumeRemoteOpen: Bool
    ) -> StartupVerifiedLocalLibraryItem {
        StartupVerifiedLocalLibraryItem(
            record: record,
            attestation: nil,
            row: StartupLibraryWork(
                reference: .cloudWork(record.workID.rawValue),
                // App registryはaccount-independent。remote projectionをここから
                // 表示するとaccount切替後に旧作品名を漏らすためgenericにする。
                title: "ダウンロードを再開する作品",
                updatedAt: record.pendingRemote?.headClientCreatedAt,
                availability: record.state == .remoteOpenPending && canResumeRemoteOpen
                    ? .remotePending
                    : record.state == .remoteOpenPending ? .remoteOnly : .unavailable,
                isTitleTruncated: record.pendingRemote?.isTitleTruncated ?? false
            )
        )
    }

    private func invalidPackageRow(
        for record: DeviceSyncLocalLibraryRecord
    ) -> StartupVerifiedLocalLibraryItem {
        StartupVerifiedLocalLibraryItem(
            record: record,
            attestation: nil,
            row: StartupLibraryWork(
                reference: .cloudWork(record.workID.rawValue),
                title: record.package?.titleProjection ?? "確認が必要な作品",
                updatedAt: record.package?.updatedAt,
                availability: .unavailable,
                isTitleTruncated: record.package.map {
                    $0.fullTitleUTF8ByteCount > $0.titleProjection.utf8.count
                } ?? false
            )
        )
    }

    private func unavailableRow(
        for record: DeviceSyncLocalLibraryRecord,
        attestation: DeviceSyncLocalPackageAttestation
    ) -> StartupVerifiedLocalLibraryItem {
        StartupVerifiedLocalLibraryItem(
            record: record,
            attestation: attestation,
            row: StartupLibraryWork(
                reference: .cloudWork(record.workID.rawValue),
                title: attestation.titleProjection,
                updatedAt: attestation.updatedAt,
                availability: .unavailable,
                isTitleTruncated: attestation.fullTitleUTF8ByteCount
                    > attestation.titleProjection.utf8.count
            )
        )
    }

    private func resolveAvailability(
        for record: DeviceSyncLocalLibraryRecord,
        attestation: DeviceSyncLocalPackageAttestation,
        library: DeviceSyncLibraryRuntime,
        context: StartupLibraryAvailabilityContext
    ) async -> StartupLibraryWorkAvailability {
        guard !context.journalNeedsReview else { return .needsReview }
        if record.state == .remoteOpenPending,
           let pendingRemote = record.pendingRemote,
           attestation.matches(pendingRemote),
           await library.hasCompletedRemoteOpenLocally(pendingRemote) {
            // Domain bind後→App registry acknowledgement前のkill窓。remote catalogが
            // offlineで空でも、exact package・pending projection・outbox-free journal
            // の3点が一致するときだけ耐久な同期済み状態へ昇格する。
            do {
                try await library.markSynced(record.workID, pendingRemote)
                return .cachedRemote
            } catch {
                return .unavailable
            }
        }
        return switch record.state {
        case .synced where record.acknowledgedRemote.map(attestation.matches) == true:
            .cachedRemote
        case .needsReview:
            .needsReview
        case .publishPending:
            context.hasPublishAuthority ? .localPending : .localOnly
        case .synced:
            .localPending
        case .remoteOpenPending:
            context.canResumeRemoteOpen ? .remotePending : .unavailable
        case .reservedForPublish:
            .unavailable
        case .accountQuarantined, .legacyPreserved:
            .unavailable
        }
    }

    private func localLibraryPackageTitle(
        workID: SyncWorkID,
        library: DeviceSyncLibraryRuntime,
        now: Date
    ) async -> (attestation: DeviceSyncLocalPackageAttestation?, document: NovelDocument?) {
        do {
            try await library.validateInstalledPackage(workID)
            let url = try await library.packageURL(workID)
            guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                return (nil, nil)
            }
            let loaded = try await portableRepository.validatePortablePackage(at: url)
            let attestation = try DeviceSyncLocalPackageAttestation(document: loaded, updatedAt: now)
            return (attestation, loaded)
        } catch {
            return (nil, nil)
        }
    }
}
