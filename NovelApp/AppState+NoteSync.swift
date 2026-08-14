import Foundation
import NovelCore
import NovelSync

extension AppState {
    var usesNoteSyncRuntime: Bool {
        deviceSyncRuntime?.makeNoteSyncCoordinator != nil
    }

    func prepareNoteSyncIfAvailable(
        for expectedIdentity: WorkSyncPreparationIdentity,
        resolvedLookup expectedLookup: DeviceSyncLookupIdentity?
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime,
              runtime.makeNoteSyncCoordinator != nil else { return false }
        startDeviceSyncSignalObservationIfNeeded()
        // CloudKit create/list shares the production actor. Never keep the
        // D-061 recovery overlay up while that actor waits on the network.
        deviceSyncLocalRecoveryPending = false
        guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }

        if let identity = activeWorkSyncIdentity,
           identity.documentSession == expectedIdentity.documentSession,
           noteSyncClient != nil {
            return true
        }

        deviceSyncState = .syncing
        deviceSyncLocalRecoveryPending = false
        let resolution: DeviceSyncBindingResolution?
        do {
            let resolver = runtime.localWorkBinding ?? runtime.binding
            resolution = try await resolver(
                expectedIdentity.documentSession,
                expectedIdentity.structureDigest
            )
        } catch {
            DeviceSyncLog.note("prepare lookup-failed", error: error)
            guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "iCloud作品同期の接続を確認できません")
            deviceSyncLocalRecoveryPending = false
            return true
        }
        guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }
        guard let resolution else {
            DeviceSyncLog.note("prepare skipped(no-binding)")
            clearWorkSyncClient()
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .unconfigured
            deviceSyncSetupState = .idle
            deviceSyncLocalRecoveryPending = false
            return true
        }

        let identity = WorkSyncDocumentIdentity(
            documentSession: expectedIdentity.documentSession,
            workID: resolution.binding.workID,
            localWorkingCopyID: resolution.binding.localWorkingCopyID
        )
        do {
            guard let coordinator = try await runtime.makeNoteSyncCoordinator?(
                identity.workID,
                identity.localWorkingCopyID
            ) else {
                DeviceSyncLog.note("prepare skipped(no-coordinator)")
                return false
            }
            let client = makeLiveNoteSyncClient(
                coordinator: coordinator,
                preflightAvailability: resolution.remoteAvailability
            )
            await prepareResolvedNoteSync(
                identity: identity,
                client: client,
                expectedIdentity: expectedIdentity,
                resolvedLookup: expectedLookup
            )
            return true
        } catch {
            DeviceSyncLog.note("prepare failed", error: error)
            guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }
            deviceSyncState = .blocked
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            return true
        }
    }

    private func prepareResolvedNoteSync(
        identity: WorkSyncDocumentIdentity,
        client: NoteSyncClient,
        expectedIdentity: WorkSyncPreparationIdentity,
        resolvedLookup expectedLookup: DeviceSyncLookupIdentity?
    ) async {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentWorkSyncPreparationIdentity == expectedIdentity else { return }
            guard beginDocumentTransition() else { return }
            defer { endDocumentTransition() }

            guard await captureAndSaveActiveWorkSyncEditorIfNeeded(),
                  let packageSnapshot = await readCurrentWorkSyncPackageSnapshotAtPreparedBoundary(
                      expectedSession: identity.documentSession
                  ),
                  (try? WorkSnapshot(document: document)) == packageSnapshot else {
                deviceSyncLocalDurabilityState = .failed
                return
            }

            do {
                _ = try await client.coordinator.recordPackageSave(packageSnapshot)
                guard documentSessionToken == identity.documentSession else { return }
                activeWorkSyncIdentity = identity
                noteSyncClient = client
                workSyncClient = nil
                isCurrentWorkBoundToCloud = true
                deviceSyncLocalDurabilityState = .saved
                deviceSyncLocalRecoveryPending = false
                resolvedDeviceSyncLookupIdentity = currentDeviceSyncLookupIdentity ?? expectedLookup
                let dirty = try await client.coordinator.state().dirty
                applyNoteSyncIdleState(client: client, dirty: dirty)
            } catch {
                guard documentSessionToken == identity.documentSession else { return }
                deviceSyncState = .blocked
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            }
        }
    }

    func stageNoteSyncPackageSave(
        _ document: NovelDocument
    ) async -> WorkSyncPackageSavePreparation {
        guard usesNoteSyncRuntime,
              let identity = activeWorkSyncIdentity,
              let client = noteSyncClient,
              workSyncContextIsCurrent(identity) else {
            return .notApplicable
        }
        do {
            let snapshot = try WorkSnapshot(document: document)
            guard workSyncContextIsCurrent(identity) else { return .failed }
            deviceSyncLocalDurabilityState = .pending
            deviceSyncTransferState = .localPending
            return .notePrepared(
                NoteSyncPreparedPackageSave(
                    identity: identity,
                    client: client,
                    snapshot: snapshot
                )
            )
        } catch {
            guard workSyncContextIsCurrent(identity) else { return .failed }
            deviceSyncLocalDurabilityState = .pending
            return .failed
        }
    }

    func confirmNoteSyncPackageSave(
        _ preparation: NoteSyncPreparedPackageSave
    ) async {
        guard workSyncContextIsCurrent(preparation.identity) else { return }
        do {
            _ = try await preparation.client.coordinator.recordPackageSave(preparation.snapshot)
            guard workSyncContextIsCurrent(preparation.identity) else { return }
            deviceSyncLocalDurabilityState = .saved
            let dirty = try await preparation.client.coordinator.state().dirty
            applyNoteSyncIdleState(client: preparation.client, dirty: dirty)
        } catch {
            guard workSyncContextIsCurrent(preparation.identity) else { return }
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            deviceSyncTransferState = .localPending
        }
    }

    func syncBoundNoteWorkIfNeeded() async {
        DeviceSyncLog.note("explicit begin")
        guard noteSyncConflict == nil else {
            DeviceSyncLog.note("explicit skipped(conflict)")
            return
        }
        guard let identity = activeWorkSyncIdentity else {
            DeviceSyncLog.note("explicit skipped(no-identity)")
            return
        }
        guard workSyncContextIsCurrent(identity) else {
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
            cloudLibraryActionMessage =
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
        scheduleNoteSyncNetwork(identity: identity, client: client)
        await workSyncNetworkTask?.value
        while let followUp = workSyncNetworkTask {
            await followUp.value
        }
        DeviceSyncLog.note("explicit finished(\(deviceSyncTransferState.logToken))")
    }

    func scheduleNoteSyncNetwork(
        identity: WorkSyncDocumentIdentity,
        client: NoteSyncClient
    ) {
        guard workSyncContextIsCurrent(identity) else {
            DeviceSyncLog.note("send skipped(stale-session)")
            return
        }
        guard noteSyncConflict == nil else {
            DeviceSyncLog.note("send skipped(conflict)")
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
                guard workSyncContextIsCurrent(identity) else { return }
                if send.hasConflicts {
                    let pulled = try await client.coordinator.pullRemote(onto: snapshot)
                    noteSyncConflict = pulled.conflict
                    if pulled.conflict != nil {
                        DeviceSyncLog.note("needs review conflicts=\(send.conflictedKeys.count)")
                        await markLibraryNeedsReview(identity)
                        deviceSyncState = .needsReview
                        deviceSyncTransferState = .localPending
                    } else {
                        DeviceSyncLog.note("send conflicts content-match")
                        noteSyncConflict = nil
                        deviceSyncState = .writer
                        deviceSyncTransferState = .upToDate
                    }
                } else {
                    let pulled = try await client.coordinator.pullRemote(onto: snapshot)
                    try await client.coordinator.acknowledgeReconcile(pulled)
                    if let conflict = pulled.conflict {
                        DeviceSyncLog.note("needs review conflicts=\(conflict.keys.count)")
                        noteSyncConflict = conflict
                        await markLibraryNeedsReview(identity)
                        deviceSyncState = .needsReview
                        deviceSyncTransferState = .localPending
                    } else {
                        noteSyncConflict = nil
                        deviceSyncState = .writer
                        deviceSyncTransferState = .upToDate
                        DeviceSyncLog.note("send ok")
                        if let library = deviceSyncRuntime?.library,
                           let workRecord = try await NoteSyncProjection.records(
                               workID: identity.workID,
                               snapshot: pulled.appliedSnapshot
                           ).first(where: { $0.key.kind == .work }) {
                            try? await library.markSynced(
                                identity.workID,
                                SyncWorkLibraryEntry(noteWork: workRecord)
                            )
                        }
                    }
                }
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                DeviceSyncLog.note("network failed", error: error)
                applyNoteSyncNetworkFailure(error, client: client)
            }
            let requested = workSyncNetworkRescheduleRequested
            workSyncNetworkRescheduleRequested = false
            if workSyncContextIsCurrent(identity) {
                workSyncNetworkTask = nil
            }
            guard requested, workSyncContextIsCurrent(identity) else { return }
            if noteSyncConflict != nil {
                DeviceSyncLog.note("send skip-reschedule(conflict)")
                return
            }
            if deviceSyncTransferState == .upToDate {
                DeviceSyncLog.note("send skip-reschedule(upToDate)")
                return
            }
            scheduleNoteSyncNetwork(identity: identity, client: client)
        }
    }

    func resolveNoteSyncConflict(
        using choice: NoteSyncConflictChoice,
        expectedConflict: NoteSyncConflict,
        expectedSession: DocumentSessionToken
    ) async {
        guard !isApplyingWorkSyncConflict else {
            DeviceSyncLog.note("resolve skipped(applying)")
            return
        }
        guard documentSessionToken == expectedSession else {
            DeviceSyncLog.note("resolve skipped(stale-session)")
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
        isApplyingWorkSyncConflict = true
        defer { isApplyingWorkSyncConflict = false }

        await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  workSyncContextIsCurrent(identity),
                  beginDocumentTransition() else {
                DeviceSyncLog.note("resolve skipped(transition)")
                return
            }
            defer { endDocumentTransition() }

            guard await captureAndSaveActiveWorkSyncEditorIfNeeded() else {
                DeviceSyncLog.note("resolve skipped(editor-save)")
                return
            }
            do {
                let local = try WorkSnapshot(document: document)
                let newWorkID = SyncWorkID()
                DeviceSyncLog.note("resolve fetch-and-apply")
                let resolution = try await client.coordinator.resolve(
                    choice,
                    local: local,
                    newWorkID: newWorkID,
                    expectedKeys: expectedConflict.keys
                )
                DeviceSyncLog.note("resolve applied(\(choice))")
                guard workSyncContextIsCurrent(identity) else { return }
                if choice != .keepLocal {
                    let installed = await persistAndInstallWorkSyncSnapshot(
                        resolution.currentWorkSnapshot,
                        expectedSession: identity.documentSession
                    )
                    guard installed else { return }
                }
                if choice == .keepBoth,
                   let forked = resolution.forkedSnapshot,
                   let forkedID = resolution.forkedWorkID {
                    try await installForkedNoteSyncWork(forkedID, snapshot: forked)
                }
                noteSyncConflict = nil
                deviceSyncState = .syncing
                applyNoteSyncIdleState(client: client, dirty: .empty)
                DeviceSyncLog.note("resolve ok(\(choice))")
                scheduleNoteSyncNetwork(identity: identity, client: client)
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                DeviceSyncLog.note("resolve failed(\(choice))", error: error)
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
                presentCloudLibraryActionFailure(
                    error,
                    message: "選んだ内容を保存できませんでした。この端末の作品はそのまま残っています。"
                )
            }
        }
    }

    private func installForkedNoteSyncWork(
        _ workID: SyncWorkID,
        snapshot: WorkSnapshot
    ) async throws {
        guard let library = deviceSyncRuntime?.library else { return }
        let document = try snapshot.materializedDocument()
        let destination = try await library.packageURL(workID)
        try await saveDocumentPackage(document, to: destination)
        try await library.publishNewWork(workID, document, destination)
        try await library.resumeInitialWorkPublication(workID, document, destination)
    }

    private func makeLiveNoteSyncClient(
        coordinator: NoteSyncCoordinator,
        preflightAvailability: DeviceSyncRemoteAvailability
    ) -> NoteSyncClient {
        // Local preflight stamps `.temporarilyOffline` so Editor open never waits
        // on CloudKit (D-064). Note coordinator construction already required live
        // services, so that stamp is not an explicit-send fence (D-073).
        switch preflightAvailability {
        case .available:
            return NoteSyncClient(coordinator: coordinator, remoteAvailability: .available)
        case .temporarilyOffline:
            DeviceSyncLog.note("prepare live-services(temporarilyOffline)")
            return NoteSyncClient(coordinator: coordinator, remoteAvailability: .available)
        case .configurationBlocked:
            DeviceSyncLog.note("prepare keep-fence(configurationBlocked)")
            return NoteSyncClient(
                coordinator: coordinator,
                remoteAvailability: .configurationBlocked
            )
        }
    }

    private func applyNoteSyncIdleState(client: NoteSyncClient, dirty: NoteSyncDirtySet) {
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

    private func applyNoteSyncNetworkFailure(_ error: any Error, client: NoteSyncClient) {
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
        presentCloudLibraryActionFailure(
            error,
            message: "iCloudと同期できませんでした。この端末の作品はそのまま残っています。"
        )
    }
}
