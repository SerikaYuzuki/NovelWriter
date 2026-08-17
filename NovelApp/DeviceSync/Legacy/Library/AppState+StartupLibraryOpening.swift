import AppKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    func bootstrap(opening requestedURL: URL? = nil, localFirst: Bool = false) async {
        guard !deviceSyncStartupFailedSafely else { return }
        if hasCompletedBootstrap {
            if let requestedURL {
                _ = await openExternalDocument(at: requestedURL)
            }
            return
        }

        if let requestedURL {
            pendingBootstrapOpenURL = requestedURL
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let initialOpenURL = pendingBootstrapOpenURL
        pendingBootstrapOpenURL = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap(opening: initialOpenURL, localFirst: localFirst)
        }
        bootstrapTask = task
        await task.value
    }

    /// 初回状態の確立と、そのI/O中に届いたFinder openを一つの完了境界として処理する。
    /// これにより、どの`bootstrap()`呼び出しもdelegateへ早すぎる完了を返さない。
    private func performBootstrap(opening requestedURL: URL?, localFirst: Bool) async {
        guard !deviceSyncStartupFailedSafely else { return }
        observeResignActive()
        observeSystemSleep()
        observeDeviceSyncReactivation()
        startDeviceSyncSignalObservationIfNeeded()

        await establishInitialStartupState(opening: requestedURL, localFirst: localFirst)

        while let pendingOpenURL = pendingBootstrapOpenURL {
            pendingBootstrapOpenURL = nil
            _ = await openExternalDocument(at: pendingOpenURL)
        }

        hasCompletedBootstrap = true
        bootstrapTask = nil
        if localFirst {
            scheduleStartupLibraryRemoteRefreshIfNeeded()
        }
    }

    private func establishInitialStartupState(opening requestedURL: URL?, localFirst: Bool) async {
        if usesSnapshotSyncRuntime {
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .offline,
                    isLoading: true
                )
            )
            await refreshSnapshotLibrary()
            if let requestedURL {
                _ = await importExternalDocument(at: requestedURL, expectedSession: documentSessionToken)
            }
            return
        }
        if deviceSyncRuntime?.library != nil {
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .available,
                    isLoading: true
                )
            )
            if localFirst {
                await refreshLocalStartupLibrary()
                if let requestedURL {
                    _ = await importExternalDocument(at: requestedURL, expectedSession: documentSessionToken)
                }
            } else if let requestedURL {
                await refreshStartupLibrary()
                _ = await importExternalDocument(at: requestedURL, expectedSession: documentSessionToken)
            } else {
                await refreshStartupLibrary()
            }
            return
        }
        if let requestedURL {
            await loadStartupDocument(at: requestedURL, source: .finder)
            return
        }

        let recentDocumentURL = userDefaults.string(forKey: Self.recentDocumentPathKey)
            .flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path)
            }
        startupState = .documentSelection(
            StartupDocumentSelectionContext(recentDocumentURL: recentDocumentURL)
        )
    }

    /// Recovery画面の「再試行」。同じ原本URLまたは同じ新規保存先を再利用する。
    func retryStartup() async {
        guard !deviceSyncStartupFailedSafely, !isTerminationPending else { return }
        let recoverySession = documentSessionToken
        await documentOperationGate.perform {
            await retryStartupSerially()
        }
        if startupState.isReady, documentSessionToken != recoverySession {
            // chooserから失敗した作品を再試行した場合も、EditorPaneの生成に依存せず
            // local journalを確認し終えるまで全作品変更をgateする(D-061 / D-062)。
            await prepareActiveDeviceSyncLocally()
        }
    }

    private func retryStartupSerially() async {
        guard case let .recovery(context) = startupState else { return }
        startupState = .loading

        switch context.reason {
        case .cannotOpenDocument, .protectedLocationInDebugBuild:
            guard let url = context.documentURL else {
                startupState = .recovery(context)
                return
            }
            await loadStartupDocument(at: url, source: context.source)
        case .cannotCreateDocument:
            await createInitialDocumentForStartup(at: context.documentURL)
        case .deviceSyncSafetyUnavailable:
            startupState = .recovery(context)
        }
    }

    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        pendingBootstrapOpenURL = nil
        startupState = .recovery(
            StartupRecoveryContext(
                reason: .deviceSyncSafetyUnavailable,
                source: .initialDocument,
                documentURL: nil
            )
        )
    }

    /// Finder / Open Withから渡された作品を、現在作品を守る通常の切替経路で開く。
    @discardableResult
    func openExternalDocument(at url: URL) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        let success = if deviceSyncRuntime?.library != nil {
            await importExternalDocument(at: url, expectedSession: documentSessionToken)
        } else {
            await openDocument(at: url, expectedSession: nil, startupSource: .finder)
        }
        if !success {
            externalDocumentOpenErrorMessage = if deviceSyncRuntime?.library != nil {
                "作品を取り込めませんでした。原本と表示中の作品は変更していません。形式、空き容量、アクセス権限を確認してください。"
            } else {
                "作品を開けませんでした。原稿は切り替えていません。ファイルとアクセス権限を確認してください。"
            }
        }
        return success
    }

    /// D-063の外部packageはopen-in-placeしない。validated package transportが
    /// private stagingへinstallする実装境界（後段でrepository能力を必須化）。
    @discardableResult
    func importExternalDocument(
        at sourceURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        guard let portableRepository = repository as? PortableDocumentPackageRepository,
              deviceSyncRuntime?.library != nil,
              permitsCloudLibraryMutation,
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        let source = sourceURL.standardizedFileURL
        let importedDocument: NovelDocument
        do {
            importedDocument = try await portableRepository.validatePortablePackage(at: source)
        } catch {
            return false
        }
        let publication = await performForCurrentDocument(
            expectedSession: expectedSession,
            ifStale: PendingPrivateLibraryPublication?.none
        ) {
            await createPrivateLibraryWorkSerially(
                importedDocument,
                portableSourceURL: source,
                portableRepository: portableRepository
            )
        }
        if let publication {
            // Legacy visible package remains untouched. Its preference is retired only
            // after private registry+package durability has succeeded.
            userDefaults.removeObject(forKey: Self.recentDocumentPathKey)
            schedulePrivateLibraryPublish(publication)
            await prepareActiveDeviceSyncLocally()
        }
        return publication != nil
    }

    /// 起動画面に表示した前回作品を、その画面を表示したsessionにだけ適用する。
    /// recent URLは表示しただけでは読み込まず、ここで初めてRepositoryへ渡す(D-062)。
    @discardableResult
    func openRecentDocument(expectedSession: DocumentSessionToken) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              let recentDocument = context.recentDocument else { return false }
        return await openDocument(
            at: recentDocument.url,
            expectedSession: expectedSession,
            startupSource: .recentDocument
        )
    }

    /// 起動画面で選んだ作品を、表示時のexact referenceに従って開く。
    /// local pathはViewへ表示せず、cloud workはworkIDだけを選択identityにする。
    @discardableResult
    func openStartupLibraryWork(
        _ reference: StartupLibraryWorkReference,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              context.works.contains(where: { $0.reference == reference }),
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        if usesSnapshotSyncRuntime {
            return await openSnapshotLibraryWork(
                reference,
                context: context,
                expectedSession: expectedSession
            )
        }
        switch reference {
        case let .recentDocument(url):
            return await openDocument(
                at: url,
                expectedSession: expectedSession,
                startupSource: .recentDocument
            )
        case let .cloudWork(rawWorkID):
            guard let selected = context.works.first(where: { $0.reference == reference }) else {
                return false
            }
            let workID = SyncWorkID(rawValue: rawWorkID)
            switch selected.availability {
            case .cachedRemote, .localPending, .localOnly, .needsReview:
                return await openVerifiedLocalLibraryWork(
                    workID,
                    expectedRow: selected,
                    expectedSession: expectedSession
                )
            case .remoteOnly where context.connection == .available:
                guard let entry = startupRemoteLibraryEntries[workID] else { return false }
                return await downloadAndOpenLibraryWork(
                    entry,
                    expectedRow: selected,
                    expectedSession: expectedSession
                )
            case .remotePending:
                return await resumeAndOpenPendingLibraryWork(
                    workID,
                    expectedRow: selected,
                    expectedSession: expectedSession
                )
            case .remoteOnly, .cloudUnavailable, .unavailable:
                return false
            }
        }
    }

    private func openVerifiedLocalLibraryWork(
        _ workID: SyncWorkID,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard let library = deviceSyncRuntime?.library else { return false }
        let opened = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  case let .documentSelection(context) = startupState,
                  context.works.contains(expectedRow) else { return false }
            do {
                let inventory = try await library.loadLocalInventory()
                guard let record = inventory.records.first(where: { $0.workID == workID }),
                      let recordedPackage = record.package else { return false }
                try await library.validateInstalledPackage(workID)
                let url = try await library.packageURL(workID)
                guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                    return false
                }
                let loaded = try await portableRepository.validatePortablePackage(at: url)
                try await library.validateInstalledPackage(workID)
                let attestation = try DeviceSyncLocalPackageAttestation(
                    document: loaded,
                    updatedAt: recordedPackage.updatedAt
                )
                guard attestation.documentID == record.expectedDocumentID else { return false }
                switch expectedRow.availability {
                case .cachedRemote:
                    guard record.state == .synced,
                          record.acknowledgedRemote.map(attestation.matches) == true else {
                        return false
                    }
                case .localPending:
                    guard record.state == .publishPending || record.state == .synced else {
                        return false
                    }
                case .localOnly:
                    guard record.state == .publishPending,
                          await library.hasLocalPublishAuthority(
                              workID,
                              record.expectedDocumentID
                          ) == false else { return false }
                case .needsReview:
                    // The work journal can discover a review before the local
                    // library registry is promoted from `publishPending` to
                    // `needsReview` (for example after a restart during a
                    // first publish). The package has already passed local
                    // readback, so it is safe to open it; the active work
                    // boundary will keep the unresolved review visible and
                    // control editing.
                    guard record.state != .reservedForPublish else {
                        return false
                    }
                case .remoteOnly, .remotePending, .cloudUnavailable, .unavailable:
                    return false
                }
                let loadedAttachments = try await loadAttachmentsThrowing(for: url)
                installDocument(loaded, at: url, attachments: loadedAttachments)
                return startupState.isReady
            } catch {
                return false
            }
        }
        if opened {
            await prepareActiveDeviceSyncLocally()
        } else {
            scheduleStartupLibraryRemoteRefreshIfNeeded()
        }
        return opened
    }

    private func downloadAndOpenLibraryWork(
        _ expectedEntry: SyncWorkLibraryEntry,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        await materializeAndOpenLibraryWork(
            workID: expectedEntry.workID,
            expectedCatalogEntry: expectedEntry,
            expectedRow: expectedRow,
            expectedSession: expectedSession
        )
    }

    private func resumeAndOpenPendingLibraryWork(
        _ workID: SyncWorkID,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        await materializeAndOpenLibraryWork(
            workID: workID,
            expectedCatalogEntry: nil,
            expectedRow: expectedRow,
            expectedSession: expectedSession
        )
    }

    private func materializeAndOpenLibraryWork(
        workID: SyncWorkID,
        expectedCatalogEntry: SyncWorkLibraryEntry?,
        expectedRow: StartupLibraryWork,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return false }
        let opened = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  case let .documentSelection(context) = startupState,
                  context.works.contains(expectedRow) else {
                return false
            }
            if let expectedCatalogEntry {
                guard context.connection == .available,
                      startupRemoteLibraryEntries[workID] == expectedCatalogEntry else {
                    return false
                }
            }

            var stagingURL: URL?
            do {
                guard let portableRepository = repository as? PortableDocumentPackageRepository else {
                    return false
                }
                let inventory = try await library.loadLocalInventory()
                let pendingRecord = inventory.records.first {
                    $0.workID == workID && $0.state == .remoteOpenPending
                }
                let prepared: DeviceSyncPreparedLibraryWork
                if let pendingRecord, let pendingEntry = pendingRecord.pendingRemote {
                    // Once Domain has staged A, never replace it with moving head B.
                    // A is installed/bound first; ordinary WorkSync then follows B.
                    prepared = try await library.resumeRemoteOpen(workID)
                    guard prepared.entry == pendingEntry else { return false }
                } else if let expectedCatalogEntry {
                    // Domain first persists the account-scoped exact intent and stages the
                    // immutable revision. App registry is written only after that succeeds,
                    // avoiding an account-independent A intent that cannot follow catalog B.
                    prepared = try await library.prepareRemoteOpen(expectedCatalogEntry)
                    guard prepared.entry == expectedCatalogEntry else { return false }
                    try await library.beginRemoteOpen(prepared.entry)
                } else {
                    // Domain pending may outlive a process killed before App registry write.
                    prepared = try await library.resumeRemoteOpen(workID)
                    try await library.beginRemoteOpen(prepared.entry)
                }
                guard prepared.entry.workID == workID,
                      try prepared.packageSnapshot == WorkSnapshot(document: prepared.document) else {
                    return false
                }

                let finalURL = try await library.packageURL(workID)
                let finalDocument: NovelDocument
                if await (try? library.validateInstalledPackage(workID)) != nil {
                    // Crash-resume never replaces an existing final package. It must be the
                    // immutable prepared revision or the work is quarantined.
                    let existing = try await portableRepository.validatePortablePackage(at: finalURL)
                    guard try WorkSnapshot(document: existing) == prepared.packageSnapshot else {
                        let existingAttestation = try DeviceSyncLocalPackageAttestation(
                            document: existing,
                            updatedAt: runtime.now()
                        )
                        try await library.quarantineInstalledPackage(
                            workID,
                            existingAttestation
                        )
                        return false
                    }
                    finalDocument = existing
                } else {
                    let staging = try await library.stagingPackageURL(workID)
                    stagingURL = staging
                    try await repository.save(prepared.document, to: staging)
                    try await library.validateStagingPackage(staging, workID)
                    let stagedReadback = try await portableRepository.validatePortablePackage(at: staging)
                    guard try WorkSnapshot(document: stagedReadback) == prepared.packageSnapshot else {
                        return false
                    }
                    let installed = try await library.installStagingPackage(
                        staging,
                        workID
                    )
                    stagingURL = nil
                    guard installed == finalURL else { return false }
                    try await library.validateInstalledPackage(workID)
                    finalDocument = try await portableRepository.validatePortablePackage(at: finalURL)
                    guard try WorkSnapshot(document: finalDocument) == prepared.packageSnapshot else {
                        return false
                    }
                }

                let attestation = try DeviceSyncLocalPackageAttestation(
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
                let loadedAttachments = try await loadAttachmentsThrowing(for: finalURL)
                installDocument(finalDocument, at: finalURL, attachments: loadedAttachments)
                return startupState.isReady
            } catch {
                if let stagingURL {
                    try? await library.discardStagingPackage(stagingURL, workID)
                }
                return false
            }
        }
        if opened {
            await prepareActiveDeviceSyncLocally()
        } else {
            scheduleStartupLibraryRemoteRefreshIfNeeded()
        }
        return opened
    }

    private func loadStartupDocument(at url: URL, source: StartupDocumentSource) async {
        guard !deviceSyncStartupFailedSafely else { return }
        let targetURL = url.standardizedFileURL
        do {
            let loadedDocument = try await repository.load(from: targetURL)
            let loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
            installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        } catch {
            print("[FUMINIWA] 起動作品を開けませんでした(\(Self.errorCategory(error)))")
            startupState = .recovery(
                StartupRecoveryContext(
                    reason: .cannotOpenDocument,
                    source: source,
                    documentURL: targetURL
                )
            )
        }
    }

    private func createInitialDocumentForStartup(at preferredURL: URL? = nil) async {
        guard !deviceSyncStartupFailedSafely else { return }
        let newDocument = NovelDocument.newDocument()
        let newURL = preferredURL
            ?? Self.availableSaveURL(
                forTitle: newDocument.title,
                fileManager: fileManager,
                directoryName: defaultDocumentDirectoryName
            )

        do {
            try await repository.save(newDocument, to: newURL)
            let newAttachments = try await loadAttachmentsThrowing(for: newURL)
            installDocument(newDocument, at: newURL, attachments: newAttachments)
        } catch {
            print("[FUMINIWA] 起動時の新規作品を保存できませんでした(\(Self.errorCategory(error)))")
            startupState = .recovery(
                StartupRecoveryContext(
                    reason: .cannotCreateDocument,
                    source: .initialDocument,
                    documentURL: newURL
                )
            )
        }
    }
}
