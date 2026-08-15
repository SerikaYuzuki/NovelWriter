import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
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
}
