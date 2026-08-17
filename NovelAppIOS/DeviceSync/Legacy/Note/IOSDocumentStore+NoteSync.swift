import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    var usesNoteSyncRuntime: Bool {
        deviceSyncRuntime?.makeNoteSyncCoordinator != nil
    }

    func prepareNoteDeviceSyncSerially(
        expectedLookup: IOSWorkSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async {
        startDeviceSyncSignalObservationIfNeeded()
        deviceSyncState = .syncing
        deviceSyncLocalRecoveryPending = false

        let digest: SyncWorkStructureDigest
        do {
            digest = try SyncWorkStructureDigest(chapters: document.chapters)
        } catch {
            continuePackageOnlyAfterWorkSyncPreflightFailure("作品の同期情報を作成できませんでした。")
            return
        }

        let resolution: IOSDeviceSyncBindingResolution?
        do {
            let resolver = runtime.localWorkBinding ?? runtime.binding
            resolution = try await resolver(
                expectedLookup.documentSession.workingCopyID,
                expectedLookup.sourceDocumentID,
                digest
            )
        } catch {
            DeviceSyncLog.note("prepare lookup-failed", error: error)
            guard currentWorkSyncLookupIdentity == expectedLookup else { return }
            continuePackageOnlyAfterWorkSyncPreflightFailure("端末内の同期情報を確認できませんでした。")
            return
        }
        guard currentWorkSyncLookupIdentity == expectedLookup else { return }
        guard let resolution else {
            DeviceSyncLog.note("prepare skipped(no-binding)")
            deviceSyncState = .unconfigured
            deviceSyncSetupState = .idle
            return
        }

        let identity = IOSWorkSyncIdentity(
            documentSession: expectedLookup.documentSession,
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            workID: resolution.binding.workID
        )
        do {
            guard let coordinator = try await runtime.makeNoteSyncCoordinator?(
                identity.workID,
                identity.localWorkingCopyID
            ) else {
                DeviceSyncLog.note("prepare skipped(no-coordinator)")
                return
            }
            let client = makeLiveNoteSyncClient(
                coordinator: coordinator,
                preflightAvailability: resolution.remoteAvailability
            )
            let snapshot = try WorkSnapshot(document: document)
            _ = try await coordinator.recordPackageSave(snapshot)
            guard currentWorkSyncLookupIdentity == expectedLookup else { return }
            noteSyncClient = client
            workSyncClient = nil
            activeWorkSyncIdentity = identity
            deviceSyncSetupState = .configured
            deviceSyncLocalDurabilityState = .saved
            deviceSyncLocalRecoveryPending = false
            let noteState = try await coordinator.state()
            if let pending = NoteSyncConflict.pending(in: noteState) {
                noteSyncConflict = pending
            } else {
                // The old Work/Episode journal is not implicitly migrated into
                // the Note protocol. Keep its exact review payload for the
                // explicit legacy recovery surface.
                noteSyncConflict = nil
            }
            if noteSyncConflict != nil {
                DeviceSyncLog.note("prepare restored-conflict keys=\(noteSyncConflict?.keys.count ?? 0)")
                await markLibraryNeedsReview(identity)
            }
            applyNoteSyncIdleState(client: client, dirty: noteState.dirty)
        } catch {
            DeviceSyncLog.note("prepare failed", error: error)
            guard currentWorkSyncLookupIdentity == expectedLookup else { return }
            continuePackageOnlyAfterWorkSyncPreflightFailure("作品同期の準備に失敗しました。")
        }
    }

    func performCoordinatedNoteDocumentSave(
        _ savedDocument: NovelDocument,
        to url: URL,
        identity: IOSWorkSyncIdentity,
        client: IOSNoteSyncClient
    ) async throws {
        guard let privateWorkingCopyLocation else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let snapshot = try WorkSnapshot(document: savedDocument)
        _ = try privateWorkingCopyLocation.attestPackage(at: url)
        try await repository.save(savedDocument, to: url)
        noteDeviceSyncPackageSaved(savedDocument)
        _ = try privateWorkingCopyLocation.attestPackage(at: url)
        try await recordCloudLibraryPackageMutationIfNeeded(savedDocument, at: url)
        _ = try await client.coordinator.recordPackageSave(snapshot)
        guard workSyncContextIsCurrent(identity) else { return }
        deviceSyncLocalDurabilityState = .saved
        let dirty = try await client.coordinator.state().dirty
        applyNoteSyncIdleState(client: client, dirty: dirty)
    }

    var canExplicitlySyncCurrentWork: Bool {
        if usesSnapshotSyncRuntime {
            return startupState == .ready && authSession != nil && !isSnapshotSyncInFlight
        }
        return startupState == .ready &&
            usesNoteSyncRuntime &&
            noteSyncClient != nil &&
            noteSyncConflict == nil
    }

    var isExplicitNoteSyncInFlight: Bool {
        if usesSnapshotSyncRuntime {
            return isSnapshotSyncInFlight
        }
        return noteSyncClient != nil && workSyncNetworkTask != nil
    }

    var presentedDeviceSyncTransferState: IOSDeviceSyncTransferState {
        isExplicitNoteSyncInFlight ? .uploading : deviceSyncTransferState
    }

    var deviceSyncEditorStatus: IOSDeviceSyncEditorStatusKind {
        IOSDeviceSyncEditorStatusKind.resolveForCurrentWork(
            saveState: saveState,
            syncState: deviceSyncState,
            transferState: presentedDeviceSyncTransferState,
            localDurability: deviceSyncLocalDurabilityState,
            hasLocalRecoveryReview: deviceSyncLocalRecoveryReview != nil
                || workSyncLocalRecoveryReview != nil
                || workSyncConflictReview != nil
                || noteSyncConflict != nil,
            isLocalRecoveryReviewReady: workSyncLocalRecoveryReview != nil
                || !deviceSyncLocalRecoveryPending,
            usesWholeWorkSync: usesWholeWorkDeviceSync
        )
    }

    @discardableResult
    func saveAndSyncNow() async -> Bool {
        DeviceSyncLog.note("explicit requested")
        guard startupState == .ready else {
            DeviceSyncLog.note("explicit skipped(not-ready)")
            return false
        }
        // Seal the work/session at the button invocation. `saveNow()` can
        // suspend while navigation opens another work; do not sync whichever
        // identity happens to be active when the save finally returns.
        let expectedSession = currentDocumentSessionToken
        let expectedIdentity = activeWorkSyncIdentity
        let saved = await saveNow()
        guard saved else {
            DeviceSyncLog.note("explicit skipped(local-save-failed)")
            return false
        }
        guard currentDocumentSessionToken == expectedSession else {
            DeviceSyncLog.note("explicit skipped(stale-session-after-save)")
            return false
        }
        if let expectedIdentity {
            guard activeWorkSyncIdentity == expectedIdentity,
                  workSyncContextIsCurrent(expectedIdentity) else {
                DeviceSyncLog.note("explicit skipped(stale-identity-after-save)")
                return false
            }
            await syncBoundNoteWorkIfNeeded(expectedIdentity: expectedIdentity)
        }
        return saved
    }

    func syncBoundNoteWorkIfNeeded(
        expectedIdentity: IOSWorkSyncIdentity? = nil
    ) async {
        DeviceSyncLog.note("explicit begin")
        guard noteSyncConflict == nil else {
            DeviceSyncLog.note("explicit skipped(conflict)")
            return
        }
        guard let identity = expectedIdentity ?? activeWorkSyncIdentity else {
            DeviceSyncLog.note("explicit skipped(no-identity)")
            return
        }
        guard activeWorkSyncIdentity == identity,
              workSyncContextIsCurrent(identity) else {
            DeviceSyncLog.note("explicit skipped(stale-session)")
            return
        }
        guard let client = noteSyncClient else {
            DeviceSyncLog.note("explicit skipped(no-client)")
            return
        }
        if !client.remoteSynchronizationAllowed {
            DeviceSyncLog.note("explicit skipped(availability=\(client.remoteAvailability.logToken))")
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
            operationErrorMessage =
                "iCloudに接続できないため同期できませんでした。この端末の作品はそのまま残っています。"
            return
        }
        DeviceSyncLog.note("explicit send")
        if let inFlight = workSyncNetworkTask {
            workSyncNetworkRescheduleRequested = true
            await inFlight.value
            while let followUp = workSyncNetworkTask {
                await followUp.value
            }
            DeviceSyncLog.note("explicit coalesced")
            return
        }
        scheduleNoteSyncNetwork(expectedIdentity: identity)
        await workSyncNetworkTask?.value
        while let followUp = workSyncNetworkTask {
            await followUp.value
        }
        DeviceSyncLog.note("explicit finished(\(deviceSyncTransferState.logToken))")
    }

    func scheduleNoteSyncNetwork(expectedIdentity: IOSWorkSyncIdentity) {
        guard workSyncContextIsCurrent(expectedIdentity) else {
            DeviceSyncLog.note("send skipped(stale-session)")
            return
        }
        guard noteSyncConflict == nil else {
            DeviceSyncLog.note("send skipped(conflict)")
            return
        }
        guard let client = noteSyncClient else {
            DeviceSyncLog.note("send skipped(no-client)")
            return
        }
        guard client.remoteSynchronizationAllowed else {
            DeviceSyncLog.note("send skipped(availability=\(client.remoteAvailability.logToken))")
            return
        }
        if workSyncNetworkTask != nil {
            workSyncNetworkRescheduleRequested = true
            return
        }
        deviceSyncTransferState = .uploading
        workSyncNetworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try WorkSnapshot(document: document)
                let send = try await client.coordinator.publishLocal(snapshot)
                guard workSyncContextIsCurrent(expectedIdentity) else { return }
                if send.hasConflicts {
                    let pulled = try await client.coordinator.pullRemote(onto: snapshot)
                    noteSyncConflict = pulled.conflict
                    if pulled.conflict != nil {
                        DeviceSyncLog.note("needs review conflicts=\(send.conflictedKeys.count)")
                        deviceSyncState = .needsReview
                        deviceSyncTransferState = .localPending
                    } else {
                        guard await materializeNoteSyncRemoteSnapshot(
                            pulled.appliedSnapshot,
                            identity: expectedIdentity,
                            expectedLocal: snapshot
                        ) else {
                            deviceSyncTransferState = .localPending
                            return
                        }
                        try await client.coordinator.acknowledgeReconcile(pulled)
                        DeviceSyncLog.note("send conflicts content-match")
                        noteSyncConflict = nil
                        deviceSyncState = .writer
                        deviceSyncTransferState = .upToDate
                        if let library = deviceSyncRuntime?.library,
                           let workRecord = try NoteSyncProjection.records(
                               workID: expectedIdentity.workID,
                               snapshot: pulled.appliedSnapshot
                           ).first(where: { $0.key.kind == .work }) {
                            try? await library.markSynced(
                                expectedIdentity.workID,
                                SyncWorkLibraryEntry(noteWork: workRecord)
                            )
                        }
                    }
                } else {
                    let pulled = try await client.coordinator.pullRemote(onto: snapshot)
                    if let conflict = pulled.conflict {
                        DeviceSyncLog.note("needs review conflicts=\(conflict.keys.count)")
                        noteSyncConflict = conflict
                        deviceSyncState = .needsReview
                        deviceSyncTransferState = .localPending
                    } else {
                        guard await materializeNoteSyncRemoteSnapshot(
                            pulled.appliedSnapshot,
                            identity: expectedIdentity,
                            expectedLocal: snapshot
                        ) else {
                            deviceSyncTransferState = .localPending
                            return
                        }
                        try await client.coordinator.acknowledgeReconcile(pulled)
                        noteSyncConflict = nil
                        deviceSyncState = .writer
                        deviceSyncTransferState = .upToDate
                        DeviceSyncLog.note("send ok")
                        if let library = deviceSyncRuntime?.library,
                           let workRecord = try NoteSyncProjection.records(
                               workID: expectedIdentity.workID,
                               snapshot: pulled.appliedSnapshot
                           ).first(where: { $0.key.kind == .work }) {
                            try? await library.markSynced(
                                expectedIdentity.workID,
                                SyncWorkLibraryEntry(noteWork: workRecord)
                            )
                        }
                    }
                }
            } catch {
                guard workSyncContextIsCurrent(expectedIdentity) else { return }
                DeviceSyncLog.note("network failed", error: error)
                applyNoteSyncNetworkFailure(error, client: client)
            }
            let requested = workSyncNetworkRescheduleRequested
            workSyncNetworkRescheduleRequested = false
            if workSyncContextIsCurrent(expectedIdentity) {
                workSyncNetworkTask = nil
            }
            guard requested, workSyncContextIsCurrent(expectedIdentity) else { return }
            if noteSyncConflict != nil {
                DeviceSyncLog.note("send skip-reschedule(conflict)")
                return
            }
            if deviceSyncTransferState == .upToDate {
                DeviceSyncLog.note("send skip-reschedule(upToDate)")
                return
            }
            scheduleNoteSyncNetwork(expectedIdentity: expectedIdentity)
        }
    }

    func resolveNoteSyncConflict(
        using choice: NoteSyncConflictChoice,
        expectedConflict: NoteSyncConflict
    ) async {
        guard !workSyncIsApplyingConflict else {
            DeviceSyncLog.note("resolve skipped(applying)")
            return
        }
        guard noteSyncConflict == expectedConflict else {
            DeviceSyncLog.note("resolve skipped(stale-conflict)")
            return
        }
        guard let identity = activeWorkSyncIdentity else {
            DeviceSyncLog.note("resolve skipped(no-identity)")
            return
        }
        guard let client = noteSyncClient else {
            DeviceSyncLog.note("resolve skipped(no-client)")
            return
        }
        guard workSyncContextIsCurrent(identity) else {
            DeviceSyncLog.note("resolve skipped(stale-session)")
            return
        }
        DeviceSyncLog.note("resolve begin(\(choice))")
        workSyncIsApplyingConflict = true
        defer { workSyncIsApplyingConflict = false }
        await documentOperationGate.perform { [weak self] in
            guard let self else { return }
            guard workSyncContextIsCurrent(identity),
                  beginDeviceSyncBoundaryTransition() else {
                DeviceSyncLog.note("resolve skipped(stale-session)")
                return
            }
            defer { endDeviceSyncBoundaryTransition() }
            do {
                let local = try WorkSnapshot(document: document)
                DeviceSyncLog.note("resolve fetch-and-apply")
                let resolution = try await client.coordinator.resolve(
                    choice,
                    local: local,
                    newWorkID: SyncWorkID(),
                    expectedKeys: expectedConflict.keys
                )
                DeviceSyncLog.note("resolve applied(\(choice))")
                if choice != .keepLocal {
                    if choice == .keepBoth,
                       let forked = resolution.forkedSnapshot,
                       let forkedID = resolution.forkedWorkID {
                        try await installForkedNoteSyncWork(forkedID, snapshot: forked)
                    }
                    guard await rewriteObservedWorkPackage(
                        resolution.currentWorkSnapshot,
                        expectedIdentity: identity
                    ) else { return }
                    try await client.coordinator.commitResolution(resolution)
                }
                noteSyncConflict = nil
                deviceSyncState = .syncing
                let dirty = try await client.coordinator.state().dirty
                applyNoteSyncIdleState(client: client, dirty: dirty)
                DeviceSyncLog.note("resolve ok(\(choice))")
                scheduleNoteSyncNetwork(expectedIdentity: identity)
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                DeviceSyncLog.note("resolve failed(\(choice))", error: error)
                deviceSyncState = .needsReview
                operationErrorMessage = DeviceSyncLog.userFacingMessage(
                    "選んだ内容を保存できませんでした。この端末の作品はそのまま残っています。",
                    error: error
                )
            }
        }
    }

    private func installForkedNoteSyncWork(
        _ workID: SyncWorkID,
        snapshot: WorkSnapshot
    ) async throws {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              let portable = repository as? PortableDocumentPackageRepository else {
            throw SyncWorkLibraryError.workMismatch
        }
        let document = try snapshot.materializedDocument()
        let expected = try IOSDeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: runtime.now()
        )
        var stagingURL: URL?
        var installed = false
        try await library.reserveForPublish(workID, expected)
        do {
            let staging = try await library.stagingPackageURL(workID)
            stagingURL = staging
            try await repository.save(document, to: staging)
            try await library.validateStagingPackage(staging, workID)
            let staged = try await portable.validatePortablePackage(at: staging)
            let stagedAttestation = try IOSDeviceSyncLocalPackageAttestation(
                document: staged,
                updatedAt: expected.updatedAt
            )
            guard staged == document, stagedAttestation == expected else {
                throw IOSCloudLibraryOperationError.packageMismatch
            }
            let destination = try await library.installStagingPackage(staging, workID)
            stagingURL = nil
            installed = true
            try await library.validateInstalledPackage(workID)
            let readback = try await portable.validatePortablePackage(at: destination)
            let readbackAttestation = try IOSDeviceSyncLocalPackageAttestation(
                document: readback,
                updatedAt: expected.updatedAt
            )
            guard readback == document, readbackAttestation == expected else {
                throw IOSCloudLibraryOperationError.packageMismatch
            }
            try await library.confirmPublishPackage(workID, expected)
            try await library.publishNewWork(workID, readback, destination)
            try await library.resumeInitialWorkPublication(workID, readback, destination)
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

    private func materializeNoteSyncRemoteSnapshot(
        _ snapshot: WorkSnapshot,
        identity: IOSWorkSyncIdentity,
        expectedLocal: WorkSnapshot
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  workSyncContextIsCurrent(identity),
                  beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            guard (try? WorkSnapshot(document: document)) == expectedLocal else { return false }
            return await rewriteObservedWorkPackage(snapshot, expectedIdentity: identity)
        }
    }

    private func makeLiveNoteSyncClient(
        coordinator: NoteSyncCoordinator,
        preflightAvailability: IOSDeviceSyncRemoteAvailability
    ) -> IOSNoteSyncClient {
        switch preflightAvailability {
        case .available:
            return IOSNoteSyncClient(coordinator: coordinator, remoteAvailability: .available)
        case .temporarilyOffline:
            DeviceSyncLog.note("prepare live-services(temporarilyOffline)")
            return IOSNoteSyncClient(coordinator: coordinator, remoteAvailability: .available)
        case .configurationBlocked:
            DeviceSyncLog.note("prepare keep-fence(configurationBlocked)")
            return IOSNoteSyncClient(
                coordinator: coordinator,
                remoteAvailability: .configurationBlocked
            )
        }
    }

    private func markLibraryNeedsReview(_ identity: IOSWorkSyncIdentity) async {
        guard workSyncContextIsCurrent(identity),
              let library = deviceSyncRuntime?.library else { return }
        try? await library.markNeedsReview(identity.workID)
    }

    private func applyNoteSyncIdleState(client: IOSNoteSyncClient, dirty: NoteSyncDirtySet) {
        if noteSyncConflict != nil {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return
        }
        if !client.remoteSynchronizationAllowed {
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
            return
        }
        deviceSyncState = .writer
        deviceSyncTransferState = dirty.isEmpty ? .upToDate : .localPending
    }

    private func applyNoteSyncNetworkFailure(_ error: any Error, client: IOSNoteSyncClient) {
        deviceSyncTransferState = .localPending
        if DeviceSyncLog.looksTemporarilyOffline(error) || !client.remoteSynchronizationAllowed {
            DeviceSyncLog.note(
                "network classified-offline(availability=\(client.remoteAvailability.logToken))",
                error: error
            )
            deviceSyncState = .offlineLocal
            return
        }
        deviceSyncState = .writer
        operationErrorMessage = DeviceSyncLog.userFacingMessage(
            "iCloudと同期できませんでした。この端末の作品はそのまま残っています。",
            error: error
        )
        DeviceSyncLog.note("action failed", error: error)
    }
}
