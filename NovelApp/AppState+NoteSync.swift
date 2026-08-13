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
            guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "iCloud作品同期の接続を確認できません")
            deviceSyncLocalRecoveryPending = false
            return true
        }
        guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }
        guard let resolution else {
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
            ) else { return false }
            let client = NoteSyncClient(
                coordinator: coordinator,
                remoteAvailability: resolution.remoteAvailability
            )
            await prepareResolvedNoteSync(
                identity: identity,
                client: client,
                expectedIdentity: expectedIdentity,
                resolvedLookup: expectedLookup
            )
            return true
        } catch {
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
                applyNoteSyncIdleState(client: client)
                if client.remoteSynchronizationAllowed {
                    scheduleNoteSyncNetwork(identity: identity, client: client)
                }
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
            applyNoteSyncIdleState(client: preparation.client)
            scheduleNoteSyncNetwork(identity: preparation.identity, client: preparation.client)
        } catch {
            guard workSyncContextIsCurrent(preparation.identity) else { return }
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            deviceSyncTransferState = .localPending
        }
    }

    func scheduleNoteSyncNetwork(
        identity: WorkSyncDocumentIdentity,
        client: NoteSyncClient
    ) {
        guard workSyncContextIsCurrent(identity),
              client.remoteSynchronizationAllowed,
              noteSyncConflict == nil else { return }
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
                        print("[FUMINIWA] note-sync needs review conflicts=\(send.conflictedKeys.count)")
                        await markLibraryNeedsReview(identity)
                        deviceSyncState = .needsReview
                        deviceSyncTransferState = .localPending
                    }
                } else {
                    let pulled = try await client.coordinator.pullRemote(onto: snapshot)
                    try await client.coordinator.acknowledgeReconcile(pulled)
                    if let conflict = pulled.conflict {
                        print("[FUMINIWA] note-sync needs review conflicts=\(conflict.keys.count)")
                        noteSyncConflict = conflict
                        await markLibraryNeedsReview(identity)
                        deviceSyncState = .needsReview
                        deviceSyncTransferState = .localPending
                    } else {
                        noteSyncConflict = nil
                        deviceSyncState = .writer
                        deviceSyncTransferState = .upToDate
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
                print("[FUMINIWA] note-sync network failed(\(String(reflecting: type(of: error))))")
                deviceSyncState = .offlineLocal
                deviceSyncTransferState = .localPending
            }
            let requested = workSyncNetworkRescheduleRequested
            workSyncNetworkRescheduleRequested = false
            if workSyncContextIsCurrent(identity) {
                workSyncNetworkTask = nil
            }
            guard requested, workSyncContextIsCurrent(identity) else { return }
            scheduleNoteSyncNetwork(identity: identity, client: client)
        }
    }

    func resolveNoteSyncConflict(
        using choice: NoteSyncConflictChoice,
        expectedConflict: NoteSyncConflict,
        expectedSession: DocumentSessionToken
    ) async {
        guard !isApplyingWorkSyncConflict,
              documentSessionToken == expectedSession,
              noteSyncConflict == expectedConflict,
              let identity = activeWorkSyncIdentity,
              let client = noteSyncClient,
              workSyncContextIsCurrent(identity) else { return }
        isApplyingWorkSyncConflict = true
        defer { isApplyingWorkSyncConflict = false }

        await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  workSyncContextIsCurrent(identity),
                  beginDocumentTransition() else { return }
            defer { endDocumentTransition() }

            guard await captureAndSaveActiveWorkSyncEditorIfNeeded() else { return }
            do {
                let local = try WorkSnapshot(document: document)
                let newWorkID = SyncWorkID()
                let resolution = try await client.coordinator.resolve(
                    choice,
                    local: local,
                    newWorkID: newWorkID
                )
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
                applyNoteSyncIdleState(client: client)
                scheduleNoteSyncNetwork(identity: identity, client: client)
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
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

    private func applyNoteSyncIdleState(client: NoteSyncClient) {
        if noteSyncConflict != nil {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return
        }
        deviceSyncState = client.remoteSynchronizationAllowed ? .writer : .offlineLocal
        deviceSyncTransferState = client.remoteSynchronizationAllowed ? .upToDate : .localPending
    }
}
