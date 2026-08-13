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
            guard currentWorkSyncLookupIdentity == expectedLookup else { return }
            continuePackageOnlyAfterWorkSyncPreflightFailure("端末内の同期情報を確認できませんでした。")
            return
        }
        guard currentWorkSyncLookupIdentity == expectedLookup else { return }
        guard let resolution else {
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
            ) else { return }
            let client = IOSNoteSyncClient(
                coordinator: coordinator,
                remoteAvailability: resolution.remoteAvailability
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
            deviceSyncState = client.remoteSynchronizationAllowed ? .writer : .offlineLocal
            if client.remoteSynchronizationAllowed {
                scheduleNoteSyncNetwork(expectedIdentity: identity)
            }
        } catch {
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
        scheduleNoteSyncNetwork(expectedIdentity: identity)
    }

    func scheduleNoteSyncNetwork(expectedIdentity: IOSWorkSyncIdentity) {
        guard workSyncContextIsCurrent(expectedIdentity),
              let client = noteSyncClient,
              client.remoteSynchronizationAllowed,
              noteSyncConflict == nil else { return }
        workSyncNetworkGeneration &+= 1
        let generation = workSyncNetworkGeneration
        workSyncNetworkTask?.cancel()
        workSyncNetworkTask = Task { @MainActor [weak self] in
            guard let self, workSyncNetworkGeneration == generation else { return }
            do {
                let snapshot = try WorkSnapshot(document: document)
                let send = try await client.coordinator.publishLocal(snapshot)
                guard workSyncContextIsCurrent(expectedIdentity) else { return }
                let pulled = try await client.coordinator.pullRemote(onto: snapshot)
                try await client.coordinator.acknowledgeReconcile(pulled)
                if let conflict = pulled.conflict ?? (send.hasConflicts ? NoteSyncConflict(
                    workID: expectedIdentity.workID,
                    keys: send.conflictedKeys
                ) : nil) {
                    print("[FUMINIWA] note-sync needs review conflicts=\(conflict.keys.count)")
                    noteSyncConflict = conflict
                    deviceSyncState = .needsReview
                    deviceSyncTransferState = .localPending
                } else {
                    noteSyncConflict = nil
                    deviceSyncState = .writer
                    deviceSyncTransferState = .upToDate
                }
            } catch {
                guard workSyncContextIsCurrent(expectedIdentity) else { return }
                print("[FUMINIWA] note-sync network failed(\(String(reflecting: type(of: error))))")
                deviceSyncState = .offlineLocal
                deviceSyncTransferState = .localPending
            }
        }
    }

    func resolveNoteSyncConflict(
        using choice: NoteSyncConflictChoice,
        expectedConflict: NoteSyncConflict
    ) async {
        guard !workSyncIsApplyingConflict,
              noteSyncConflict == expectedConflict,
              let identity = activeWorkSyncIdentity,
              let client = noteSyncClient,
              workSyncContextIsCurrent(identity) else { return }
        workSyncIsApplyingConflict = true
        defer { workSyncIsApplyingConflict = false }
        await documentOperationGate.perform { [weak self] in
            guard let self, workSyncContextIsCurrent(identity) else { return }
            do {
                let local = try WorkSnapshot(document: document)
                let resolution = try await client.coordinator.resolve(
                    choice,
                    local: local,
                    newWorkID: SyncWorkID()
                )
                if choice != .keepLocal {
                    _ = await rewriteObservedWorkPackage(
                        resolution.currentWorkSnapshot,
                        expectedIdentity: identity
                    )
                }
                if choice == .keepBoth,
                   let forked = resolution.forkedSnapshot,
                   let forkedID = resolution.forkedWorkID {
                    try await installForkedNoteSyncWork(forkedID, snapshot: forked)
                }
                noteSyncConflict = nil
                deviceSyncState = .syncing
                scheduleNoteSyncNetwork(expectedIdentity: identity)
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .needsReview
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
        try await repository.save(document, to: destination)
        try await library.publishNewWork(workID, document, destination)
        try await library.resumeInitialWorkPublication(workID, document, destination)
    }
}
