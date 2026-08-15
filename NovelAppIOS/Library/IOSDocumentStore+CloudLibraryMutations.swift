import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    func publishCloudLibraryWork(_ workID: SyncWorkID) async -> Bool {
        guard usesCloudLibrary,
              permitsCloudLibraryMutation,
              !cloudLibraryOperationInProgress,
              let item = cloudLibraryItems.first(where: { $0.id == workID }),
              item.availability.canPublishToCloud(connection: cloudLibraryConnection),
              let library = deviceSyncRuntime?.library,
              let portable = repository as? PortableDocumentPackageRepository else { return false }
        DeviceSyncLog.event("publish begin chooser")
        cloudLibraryOperationInProgress = true
        defer { cloudLibraryOperationInProgress = false }
        let published = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            do {
                try await library.validateInstalledPackage(workID)
                let url = try await library.packageURL(workID)
                let document = try await portable.validatePortablePackage(at: url)
                if startupState == .ready, activeCloudWorkID == workID {
                    DeviceSyncLog.event("publish path workbench-document")
                    try await library.publishNewWork(workID, document, url)
                } else {
                    DeviceSyncLog.event("publish path chooser-resume")
                    try await library.resumeInitialWorkPublication(workID, document, url)
                }
                DeviceSyncLog.event("publish ok")
                return true
            } catch {
                presentCloudLibraryActionFailure(
                    error,
                    message: "iCloudへ保存できませんでした。この端末の作品はそのまま残っています。"
                )
                return false
            }
        }
        _ = await refreshCloudLibrary()
        if published, startupState == .ready, activeCloudWorkID == workID {
            await refreshOrPrepareSelectedEpisodeDeviceSync()
        }
        return published
    }

    @discardableResult
    func duplicateCloudLibraryWork(_ workID: SyncWorkID) async -> Bool {
        guard usesCloudLibrary,
              permitsCloudLibraryMutation,
              !cloudLibraryOperationInProgress,
              let item = cloudLibraryItems.first(where: { $0.id == workID }),
              item.availability.canDuplicateLocalCopy,
              let library = deviceSyncRuntime?.library,
              let portable = repository as? PortableDocumentPackageRepository else { return false }
        cloudLibraryOperationInProgress = true
        defer { cloudLibraryOperationInProgress = false }
        do {
            try await library.validateInstalledPackage(workID)
            let sourceURL = try await library.packageURL(workID)
            let document = try await portable.validatePortablePackage(at: sourceURL)
            return await createCloudLibraryDocument(
                document: document,
                sourceURL: sourceURL,
                operationAlreadyClaimed: true,
                activate: false
            )
        } catch {
            presentCloudLibraryActionFailure(
                error,
                message: "作品を複製できませんでした。"
            )
            return false
        }
    }

    @discardableResult
    func removeLocalCloudLibraryWork(_ workID: SyncWorkID) async -> Bool {
        guard usesCloudLibrary,
              permitsCloudLibraryMutation,
              !cloudLibraryOperationInProgress,
              let item = cloudLibraryItems.first(where: { $0.id == workID }),
              item.availability.canRemoveLocalCopy,
              let library = deviceSyncRuntime?.library else { return false }
        cloudLibraryOperationInProgress = true
        defer { cloudLibraryOperationInProgress = false }
        let removed = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            let isActive = startupState == .ready && activeCloudWorkID == workID
            if isActive {
                return await performDocumentTransition {
                    try await library.removeLocalWork(workID)
                    detachActiveDocumentAfterLocalLibraryRemoval()
                }
            }
            do {
                try await library.removeLocalWork(workID)
                return true
            } catch {
                presentCloudLibraryActionFailure(
                    error,
                    message: "この端末の作品を外せませんでした。"
                )
                return false
            }
        }
        _ = await refreshCloudLibrary()
        return removed
    }

    func createCloudLibraryDocument(
        document newDocument: NovelDocument,
        sourceURL: URL?,
        operationAlreadyClaimed: Bool = false,
        activate: Bool = true
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

        func materializeNewWork() async throws {
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
                if activate {
                    let loadedAttachments = try await loadAttachmentsForInstall(at: finalURL)
                    guard install(finalReadback, at: finalURL, attachments: loadedAttachments) else {
                        throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                    }
                    activeCloudWorkID = workID
                    startupState = .ready
                    saveState = .saved
                }
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

        let transitioned = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            if activate {
                return await performDocumentTransition {
                    try await materializeNewWork()
                }
            }
            do {
                try await materializeNewWork()
                return true
            } catch {
                presentCloudLibraryActionFailure(
                    error,
                    message: "作品を複製できませんでした。"
                )
                return false
            }
        }
        _ = await refreshCloudLibrary()
        if transitioned, activate {
            await refreshOrPrepareSelectedEpisodeDeviceSync()
        }
        return transitioned
    }

    private func detachActiveDocumentAfterLocalLibraryRemoval() {
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentURL = libraryRoot.appendingPathComponent(
            "\(placeholder.id.uuidString).novelpkg",
            isDirectory: true
        )
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        replaceAttachments([])
        activeCloudWorkID = nil
        startupState = .library
        saveState = .saved
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        workDeviceSyncSelectionDidChange()
        userDefaults.removeObject(forKey: Self.lastDocumentNameKey)
    }

    private func presentCloudLibraryActionFailure(_ error: any Error, message: String) {
        DeviceSyncLog.event("action failed", error: error)
        operationErrorMessage = DeviceSyncLog.userFacingMessage(message, error: error)
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

    static func cloudConnection(
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

    static func addOfflineResumableRows(
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

    static func cloudLibraryItemComesBefore(
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
