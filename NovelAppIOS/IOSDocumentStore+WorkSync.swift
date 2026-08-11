import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    var currentWorkSyncLookupIdentity: IOSWorkSyncLookupIdentity? {
        guard startupState == .ready,
              let documentSession = currentDocumentSessionToken else { return nil }
        return IOSWorkSyncLookupIdentity(
            documentSession: documentSession,
            sourceDocumentID: document.id
        )
    }

    var usesWholeWorkDeviceSync: Bool {
        deviceSyncRuntime?.workTransport != nil
    }

    func workSyncContextIsCurrent(_ identity: IOSWorkSyncIdentity) -> Bool {
        activeWorkSyncIdentity == identity &&
            currentWorkSyncLookupIdentity == IOSWorkSyncLookupIdentity(
                documentSession: identity.documentSession,
                sourceDocumentID: document.id
            )
    }

    func workDeviceSyncSelectionDidChange() {
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil
        deviceSyncEditIntentTask?.cancel()
        deviceSyncEditIntentTask = nil
        activeDeviceSyncIdentity = nil
        resolvedDeviceSyncLookupIdentity = nil
        pendingDeviceSyncConflictResolution = nil
        deviceSyncConflict = nil

        if let identity = activeWorkSyncIdentity,
           identity.documentSession == currentDocumentSessionToken {
            return
        }

        workSyncNetworkTask?.cancel()
        workSyncNetworkTask = nil
        workSyncNetworkGeneration &+= 1
        workSyncNetworkDemandGeneration &+= 1
        workSyncPreparationTask?.cancel()
        workSyncPreparationTask = nil
        workSyncPreparationGeneration &+= 1
        workSyncClient = nil
        activeWorkSyncIdentity = nil
        workSyncConflictReview = nil
        workSyncLocalRecoveryReview = nil
        workSyncIsApplyingConflict = false
        deviceSyncLocalRecoveryPending = deviceSyncRuntime != nil
        deviceSyncLocalRecoveryReview = nil
        deviceSyncLocalRecoveryChoicePending = false
        deviceSyncState = deviceSyncRuntime == nil ? .unconfigured : .syncing
        deviceSyncTransferState = .notApplicable
        deviceSyncLocalDurabilityState = .notApplicable
        if case .candidates = deviceSyncSetupState {
            deviceSyncSetupState = .idle
        }
        if pendingDeviceSyncNewWork?.session != currentDocumentSessionToken {
            pendingDeviceSyncNewWork = nil
        }
    }

    func refreshOrPrepareWorkDeviceSync() async {
        guard usesWholeWorkDeviceSync,
              let expectedLookup = currentWorkSyncLookupIdentity else { return }
        if let inFlight = workSyncPreparationTask {
            await inFlight.value
            guard currentWorkSyncLookupIdentity == expectedLookup else { return }
        }
        if let identity = activeWorkSyncIdentity,
           workSyncContextIsCurrent(identity),
           workSyncClient != nil {
            await refreshWorkSyncRemoteAvailability(expectedIdentity: identity)
            await synchronizeWorkSyncAfterAvailabilityRefresh(expectedIdentity: identity)
            return
        }

        workSyncPreparationGeneration &+= 1
        let generation = workSyncPreparationGeneration
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.prepareWorkDeviceSyncSerially(expectedLookup: expectedLookup)
        }
        workSyncPreparationTask = task
        await task.value
        if workSyncPreparationGeneration == generation {
            workSyncPreparationTask = nil
        }
    }

    private func prepareWorkDeviceSyncSerially(
        expectedLookup: IOSWorkSyncLookupIdentity
    ) async {
        guard currentWorkSyncLookupIdentity == expectedLookup,
              let runtime = deviceSyncRuntime,
              let transport = runtime.workTransport else { return }
        startDeviceSyncSignalObservationIfNeeded()
        deviceSyncState = .syncing
        deviceSyncLocalRecoveryPending = true

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
            deviceSyncLocalRecoveryPending = false
            deviceSyncState = .unconfigured
            deviceSyncSetupState = .idle
            deviceSyncLocalDurabilityState = .notApplicable
            deviceSyncTransferState = .notApplicable
            return
        }
        guard let journal = resolution.workJournal else {
            continuePackageOnlyAfterWorkSyncPreflightFailure("作品同期の保存領域を確認できませんでした。")
            return
        }
        let remoteConfigurationBlocked = resolution.descriptor.map {
            $0.workID != resolution.binding.workID ||
                $0.sourceDocumentID != expectedLookup.sourceDocumentID
        } ?? false
        let initialRemoteAvailability: IOSDeviceSyncRemoteAvailability = remoteConfigurationBlocked
            ? .configurationBlocked
            : resolution.remoteAvailability

        let identity = IOSWorkSyncIdentity(
            documentSession: expectedLookup.documentSession,
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            workID: resolution.binding.workID
        )
        let coordinator = WorkSyncCoordinator(
            workID: identity.workID,
            localWorkingCopyID: identity.localWorkingCopyID,
            replicaID: runtime.replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        workSyncClient = IOSWorkSyncClient(
            coordinator: coordinator,
            remoteAvailability: initialRemoteAvailability
        )
        activeWorkSyncIdentity = identity
        deviceSyncSetupState = .configured

        let completedLocalPreparation = await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentWorkSyncLookupIdentity == expectedLookup,
                  workSyncContextIsCurrent(identity),
                  beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }

            // binding待ちの間に題名・人物・プロットなどがdirtyになっていても、
            // recovery revisionをpackageへ入れる前に必ず現在版を確定する。
            guard await saveCurrentWorkSnapshotAtPreparedBoundary() else { return false }
            do {
                let packageSnapshot = try WorkSnapshot(document: document)
                if try await coordinator.restore() == nil {
                    _ = try await coordinator.bootstrapLocalSnapshot(packageSnapshot, at: runtime.now())
                }
                let recovery = try await coordinator.reconcileLocalMaterialization(
                    packageSnapshot: packageSnapshot,
                    at: runtime.now()
                )
                guard workSyncContextIsCurrent(identity) else { return false }
                guard await applyWorkSyncLocalRecovery(
                    recovery,
                    coordinator: coordinator,
                    identity: identity
                ) else { return false }
                deviceSyncLocalRecoveryPending = false
                try await applyWorkSyncState(coordinator.currentState(), expectedIdentity: identity)
                return true
            } catch {
                return false
            }
        }
        guard completedLocalPreparation else {
            guard workSyncContextIsCurrent(identity) else { return }
            if workSyncLocalRecoveryReview == nil {
                continuePackageOnlyAfterWorkSyncPreflightFailure(
                    "端末内に保存した作品の同期履歴を復旧できませんでした。"
                )
            }
            return
        }

        if initialRemoteAvailability == .configurationBlocked {
            deviceSyncState = .blocked
            deviceSyncTransferState = .localPending
            operationErrorMessage = "iCloud側の作品情報が一致しません。端末への保存は続けられます。"
            return
        }

        await refreshWorkSyncRemoteAvailability(expectedIdentity: identity)
        await synchronizeWorkSyncAfterAvailabilityRefresh(expectedIdentity: identity)
    }

    private func applyWorkSyncLocalRecovery(
        _ recovery: WorkLocalRecoveryOutcome,
        coordinator: WorkSyncCoordinator,
        identity: IOSWorkSyncIdentity
    ) async -> Bool {
        switch recovery {
        case .consistent, .confirmedStaged, .acknowledgedRemote, .capturedUnstagedPackage:
            return true
        case let .materializeStaged(revision):
            guard await materializeWorkRevision(revision, expectedIdentity: identity) else { return false }
            do {
                try await coordinator.confirmLocalSnapshotMaterialized(
                    revision.revisionID,
                    packageSnapshot: revision.snapshot
                )
                return true
            } catch {
                return false
            }
        case let .materializeRemote(pending):
            guard await materializeWorkRevision(pending.revision, expectedIdentity: identity) else { return false }
            do {
                try await coordinator.acknowledgeRemoteMaterialization(
                    pending.revision.revisionID,
                    packageSnapshot: pending.revision.snapshot
                )
                return true
            } catch {
                return false
            }
        case let .reviewRequired(review):
            workSyncLocalRecoveryReview = review
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            deviceSyncLocalDurabilityState = .saved
            return false
        }
    }

    func resolveWorkSyncLocalRecovery(
        using choice: IOSWorkConflictReviewChoice,
        expectedReview: WorkLocalRecoveryReview
    ) async {
        guard !workSyncIsApplyingConflict,
              workSyncLocalRecoveryReview == expectedReview,
              let expectedIdentity = activeWorkSyncIdentity,
              let client = workSyncClient else { return }
        let adapter = IOSWorkLocalRecoveryPresentation(review: expectedReview)
        guard let domainChoice = adapter.domainChoice(for: choice) else { return }
        workSyncIsApplyingConflict = true
        defer { workSyncIsApplyingConflict = false }
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  workSyncContextIsCurrent(expectedIdentity),
                  workSyncLocalRecoveryReview == expectedReview,
                  beginDeviceSyncBoundaryTransition() else { return }
            defer { endDeviceSyncBoundaryTransition() }
            do {
                if case .keepObservedPackage = domainChoice {
                    guard await rewriteObservedWorkPackage(
                        expectedReview.observedPackageSnapshot,
                        expectedIdentity: expectedIdentity
                    ) else { return }
                }
                let outcome = try await client.coordinator.resolveLocalRecovery(
                    domainChoice,
                    observedPackageSnapshot: expectedReview.observedPackageSnapshot,
                    at: deviceSyncRuntime?.now() ?? Date()
                )
                guard await applyWorkSyncLocalRecovery(
                    outcome,
                    coordinator: client.coordinator,
                    identity: expectedIdentity
                ) else { return }
                workSyncLocalRecoveryReview = nil
                deviceSyncLocalRecoveryPending = false
                try await applyWorkSyncState(
                    client.coordinator.currentState(),
                    expectedIdentity: expectedIdentity
                )
                scheduleWorkSyncNetwork(expectedIdentity: expectedIdentity)
            } catch {
                guard workSyncContextIsCurrent(expectedIdentity) else { return }
                deviceSyncState = .needsReview
                deviceSyncLocalDurabilityState = .failed
            }
        }
    }

    private func rewriteObservedWorkPackage(
        _ snapshot: WorkSnapshot,
        expectedIdentity: IOSWorkSyncIdentity
    ) async -> Bool {
        guard workSyncContextIsCurrent(expectedIdentity),
              let privateWorkingCopyLocation else { return false }
        do {
            let observed = try snapshot.materializedDocument()
            _ = try privateWorkingCopyLocation.attestPackage(at: documentURL)
            try await repository.save(observed, to: documentURL)
            _ = try privateWorkingCopyLocation.attestPackage(at: documentURL)
            let loaded = try await repository.load(from: documentURL)
            guard try WorkSnapshot(document: loaded) == snapshot else { return false }
            document = loaded
            noteDeviceSyncPackageSaved(loaded)
            advanceEditorContentGeneration()
            normalizeSelectionAfterWorkMaterialization()
            saveState = .saved
            deviceSyncLocalDurabilityState = .saved
            return true
        } catch {
            return false
        }
    }

    func performCoordinatedWorkDocumentSave(
        _ savedDocument: NovelDocument,
        to url: URL
    ) async throws {
        guard let privateWorkingCopyLocation else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let expectedLookup = currentWorkSyncLookupIdentity
        let identity = activeWorkSyncIdentity
        let client = workSyncClient
        let canStage = identity.map(workSyncContextIsCurrent) == true && client != nil
        let snapshot: WorkSnapshot?
        var stagedRevision: WorkRevision?
        var syncPreparationFailed = false
        do {
            snapshot = try WorkSnapshot(document: savedDocument)
        } catch {
            // WorkSnapshotの同期上限を超えても、合法な.novelpkgの端末保存は止めない。
            snapshot = nil
            syncPreparationFailed = true
        }
        if canStage, let client, let runtime = deviceSyncRuntime, let snapshot {
            do {
                let state = try await client.coordinator.currentState()
                let isExactPendingConflictResolution = state.pendingRemoteMaterialization.map {
                    $0.kind == .conflictResolution && $0.revision.snapshot == snapshot
                } == true
                if !isExactPendingConflictResolution {
                    stagedRevision = try await client.coordinator.stageLocalSnapshot(
                        snapshot,
                        at: runtime.now()
                    )
                }
            } catch {
                // package保存は止めない。次回preflightがpackageを明示revisionとして回収する。
                syncPreparationFailed = true
            }
        }

        _ = try privateWorkingCopyLocation.attestPackage(at: url)
        try await repository.save(savedDocument, to: url)
        noteDeviceSyncPackageSaved(savedDocument)
        _ = try privateWorkingCopyLocation.attestPackage(at: url)

        if let stagedRevision, let client, let snapshot {
            do {
                let state = try await client.coordinator.currentState()
                if state.stagedLocalRevision?.revisionID == stagedRevision.revisionID {
                    try await client.coordinator.confirmLocalSnapshotMaterialized(
                        stagedRevision.revisionID,
                        packageSnapshot: snapshot
                    )
                }
                if let identity, workSyncContextIsCurrent(identity) {
                    try await applyWorkSyncState(
                        client.coordinator.currentState(),
                        expectedIdentity: identity
                    )
                    deviceSyncLocalDurabilityState = .saved
                    if !deviceSyncLocalRecoveryPending {
                        scheduleWorkSyncNetwork(expectedIdentity: identity)
                    }
                }
            } catch {
                syncPreparationFailed = true
            }
        }
        let canReportPreparationFailure = identity.map(workSyncContextIsCurrent)
            ?? (activeWorkSyncIdentity == nil && currentWorkSyncLookupIdentity == expectedLookup)
        if syncPreparationFailed, canReportPreparationFailure {
            deviceSyncLocalDurabilityState = .failed
        }
    }

    func flushPreparedWorkSyncBoundarySerially() async -> Bool {
        guard startupState == .ready,
              editorCommandSession.isDocumentTransitionPrepared else { return false }
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(content):
            guard let chapterID = selectedChapterID, let episodeID = selectedEpisodeID else { return false }
            if document.episode(episodeID)?.episode.content != content {
                installDeviceSyncEpisodeContent(
                    content,
                    chapterID: chapterID,
                    episodeID: episodeID,
                    advancesEditorGeneration: false
                )
            } else {
                saveCoordinator.markDirty()
            }
        case .notActive:
            saveCoordinator.markDirty()
        case .compositionInProgress:
            return false
        }
        guard await saveCoordinator.saveNow() else { return false }
        guard let identity = activeWorkSyncIdentity,
              workSyncContextIsCurrent(identity) else { return true }
        return await synchronizeWorkSyncAtSafeBoundary(expectedIdentity: identity)
    }

    private func saveCurrentWorkSnapshotAtPreparedBoundary() async -> Bool {
        guard startupState == .ready,
              editorCommandSession.isDocumentTransitionPrepared else { return false }
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(content):
            guard let chapterID = selectedChapterID,
                  let episodeID = selectedEpisodeID else { return false }
            if document.episode(episodeID)?.episode.content != content {
                installDeviceSyncEpisodeContent(
                    content,
                    chapterID: chapterID,
                    episodeID: episodeID,
                    advancesEditorGeneration: false
                )
            }
        case .notActive:
            break
        case .compositionInProgress:
            return false
        }
        return await saveCoordinator.saveNow()
    }

    private func workSyncPackageIsConfirmedForNetwork(
        identity: IOSWorkSyncIdentity,
        client: IOSWorkSyncClient
    ) async -> Bool {
        do {
            let packageSnapshot = try WorkSnapshot(document: document)
            let state = try await client.coordinator.currentState()
            guard workSyncContextIsCurrent(identity),
                  state.stagedLocalRevision == nil,
                  state.localHead.snapshot == packageSnapshot else {
                if workSyncContextIsCurrent(identity) {
                    // package-onlyで残った最新版を次の明示操作でjournalへ再試行する。
                    saveCoordinator.markDirty()
                    deviceSyncLocalDurabilityState = .failed
                    deviceSyncTransferState = .localPending
                    operationErrorMessage = "この端末には保存しましたが、同期準備を完了できませんでした。再試行するまで別の版は反映しません。"
                }
                return false
            }
            return true
        } catch {
            guard workSyncContextIsCurrent(identity) else { return false }
            saveCoordinator.markDirty()
            deviceSyncLocalDurabilityState = .failed
            deviceSyncTransferState = .localPending
            operationErrorMessage = "この端末には保存しましたが、同期準備を確認できませんでした。再試行するまで別の版は反映しません。"
            return false
        }
    }

    private func refreshWorkSyncRemoteAvailability(
        expectedIdentity: IOSWorkSyncIdentity
    ) async {
        guard let runtime = deviceSyncRuntime,
              workSyncContextIsCurrent(expectedIdentity),
              let currentClient = workSyncClient,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return }
        let resolution: IOSDeviceSyncBindingResolution?
        do {
            resolution = try await runtime.binding(
                expectedIdentity.documentSession.workingCopyID,
                document.id,
                digest
            )
        } catch {
            guard workSyncContextIsCurrent(expectedIdentity) else { return }
            workSyncClient = IOSWorkSyncClient(
                coordinator: currentClient.coordinator,
                remoteAvailability: .temporarilyOffline
            )
            deviceSyncState = .offlineLocal
            return
        }
        guard workSyncContextIsCurrent(expectedIdentity) else { return }
        let availability: IOSDeviceSyncRemoteAvailability = if let resolution,
                                                               resolution.binding.localWorkingCopyID == expectedIdentity.localWorkingCopyID,
                                                               resolution.binding.workID == expectedIdentity.workID,
                                                               resolution.descriptor?.workID == expectedIdentity.workID,
                                                               resolution.descriptor?.sourceDocumentID == document.id {
            .available
        } else if let resolution,
                  resolution.binding.localWorkingCopyID == expectedIdentity.localWorkingCopyID,
                  resolution.binding.workID == expectedIdentity.workID {
            resolution.remoteAvailability
        } else {
            .configurationBlocked
        }
        workSyncClient = IOSWorkSyncClient(
            coordinator: currentClient.coordinator,
            remoteAvailability: availability
        )
        if availability != .available {
            deviceSyncState = availability == .temporarilyOffline ? .offlineLocal : .blocked
        }
    }

    private func synchronizeWorkSyncAfterAvailabilityRefresh(
        expectedIdentity: IOSWorkSyncIdentity
    ) async {
        switch editorCommandSession.captureActiveCommittedText() {
        case .notActive:
            await synchronizeWorkSyncWhenEditorIsNotMounted(expectedIdentity: expectedIdentity)
        case .captured, .compositionInProgress:
            await synchronizeWorkSyncWithoutMaterializingEditor(expectedIdentity: expectedIdentity)
        }
    }

    private func synchronizeWorkSyncWithoutMaterializingEditor(
        expectedIdentity: IOSWorkSyncIdentity
    ) async {
        guard workSyncContextIsCurrent(expectedIdentity),
              !deviceSyncLocalRecoveryPending,
              workSyncConflictReview == nil,
              workSyncLocalRecoveryReview == nil,
              let client = workSyncClient,
              await workSyncPackageIsConfirmedForNetwork(
                  identity: expectedIdentity,
                  client: client
              ) else { return }
        await runWorkSyncNetworkSingleFlight(expectedIdentity: expectedIdentity)
    }

    private func synchronizeWorkSyncWhenEditorIsNotMounted(
        expectedIdentity: IOSWorkSyncIdentity
    ) async {
        guard workSyncContextIsCurrent(expectedIdentity),
              !deviceSyncLocalRecoveryPending else { return }
        guard case .notActive = editorCommandSession.captureActiveCommittedText() else { return }
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  workSyncContextIsCurrent(expectedIdentity),
                  beginDeviceSyncBoundaryTransition() else { return }
            defer { endDeviceSyncBoundaryTransition() }
            guard workSyncConflictReview == nil,
                  case .notActive = editorCommandSession.captureActiveCommittedText(),
                  await saveCurrentWorkSnapshotAtPreparedBoundary(),
                  workSyncContextIsCurrent(expectedIdentity) else { return }
            await runWorkSyncNetworkSingleFlight(expectedIdentity: expectedIdentity)
            guard workSyncContextIsCurrent(expectedIdentity),
                  workSyncConflictReview == nil else { return }
            _ = await synchronizeWorkSyncAtSafeBoundary(expectedIdentity: expectedIdentity)
        }
    }

    func scheduleWorkSyncNetwork(expectedIdentity: IOSWorkSyncIdentity) {
        workSyncNetworkDemandGeneration &+= 1
        startWorkSyncNetworkIfNeeded(
            expectedIdentity: expectedIdentity,
            followUpAttemptsRemaining: 1
        )
    }

    private func startWorkSyncNetworkIfNeeded(
        expectedIdentity: IOSWorkSyncIdentity,
        followUpAttemptsRemaining: Int
    ) {
        guard workSyncContextIsCurrent(expectedIdentity),
              workSyncLocalRecoveryReview == nil,
              workSyncNetworkTask == nil else { return }
        workSyncNetworkGeneration &+= 1
        let generation = workSyncNetworkGeneration
        let observedDemandGeneration = workSyncNetworkDemandGeneration
        workSyncNetworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await synchronizeWorkSyncNetworkOnly(expectedIdentity: expectedIdentity)
            guard !Task.isCancelled,
                  workSyncNetworkGeneration == generation,
                  workSyncContextIsCurrent(expectedIdentity) else { return }
            let hasNewDemand = workSyncNetworkDemandGeneration != observedDemandGeneration
            let needsFollowUp = await workSyncNeedsNetworkFollowUp(
                expectedIdentity: expectedIdentity
            )
            workSyncNetworkTask = nil
            guard hasNewDemand || (needsFollowUp && followUpAttemptsRemaining > 0) else { return }
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled,
                  workSyncContextIsCurrent(expectedIdentity) else { return }
            startWorkSyncNetworkIfNeeded(
                expectedIdentity: expectedIdentity,
                followUpAttemptsRemaining: hasNewDemand ? 1 : followUpAttemptsRemaining - 1
            )
        }
    }

    private func workSyncNeedsNetworkFollowUp(
        expectedIdentity: IOSWorkSyncIdentity
    ) async -> Bool {
        guard workSyncContextIsCurrent(expectedIdentity),
              workSyncConflictReview == nil,
              workSyncLocalRecoveryReview == nil,
              let client = workSyncClient,
              client.remoteSynchronizationAllowed else { return false }
        do {
            let state = try await client.coordinator.currentState()
            guard state.conflictReview == nil,
                  state.pendingRemoteMaterialization == nil,
                  state.stagedLocalRevision == nil,
                  state.pendingRevisionCount > 0 else { return false }
            if case .pending = state.reconciliationStatus {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func runWorkSyncNetworkSingleFlight(
        expectedIdentity: IOSWorkSyncIdentity
    ) async {
        let inFlightTask = workSyncNetworkTask
        // availability refresh自体を新しいnetwork demandとして登録する。
        // 旧offline callを待っている間にreadyになった場合も、旧task完了後の
        // follow-upが失われず、active Editorへはmaterializeしない。
        scheduleWorkSyncNetwork(expectedIdentity: expectedIdentity)
        if let inFlightTask {
            await inFlightTask.value
        }
        await workSyncNetworkTask?.value
    }

    private func synchronizeWorkSyncNetworkOnly(
        expectedIdentity: IOSWorkSyncIdentity
    ) async {
        guard workSyncContextIsCurrent(expectedIdentity),
              !deviceSyncLocalRecoveryPending,
              workSyncLocalRecoveryReview == nil,
              let client = workSyncClient else { return }
        guard client.remoteSynchronizationAllowed else {
            deviceSyncState = client.remoteAvailability == .temporarilyOffline ? .offlineLocal : .blocked
            return
        }
        do {
            deviceSyncTransferState = .uploading
            let outcome = try await client.coordinator.synchronize(
                at: deviceSyncRuntime?.now() ?? Date()
            )
            guard workSyncContextIsCurrent(expectedIdentity) else { return }
            applyWorkSyncOutcome(outcome, expectedIdentity: expectedIdentity)
        } catch WorkSyncTransportError.unavailable {
            guard workSyncContextIsCurrent(expectedIdentity) else { return }
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
        } catch {
            guard workSyncContextIsCurrent(expectedIdentity) else { return }
            deviceSyncState = .blocked
        }
    }

    @discardableResult
    func synchronizeWorkSyncAtSafeBoundary(
        expectedIdentity: IOSWorkSyncIdentity
    ) async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared || deviceSyncLocalRecoveryPending,
              workSyncContextIsCurrent(expectedIdentity),
              let client = workSyncClient else { return false }
        guard await workSyncPackageIsConfirmedForNetwork(
            identity: expectedIdentity,
            client: client
        ) else { return false }
        if let workSyncNetworkTask {
            await workSyncNetworkTask.value
            guard workSyncContextIsCurrent(expectedIdentity) else { return false }
        }
        guard client.remoteSynchronizationAllowed else {
            deviceSyncState = client.remoteAvailability == .temporarilyOffline ? .offlineLocal : .blocked
            return true
        }

        do {
            deviceSyncTransferState = .uploading
            let outcome = try await client.coordinator.synchronize(at: deviceSyncRuntime?.now() ?? Date())
            guard workSyncContextIsCurrent(expectedIdentity) else { return false }
            applyWorkSyncOutcome(outcome, expectedIdentity: expectedIdentity)
            let state = try await client.coordinator.currentState()
            if let pending = state.pendingRemoteMaterialization {
                guard await materializeWorkRevision(
                    pending.revision,
                    expectedIdentity: expectedIdentity
                ) else { return false }
                try await client.coordinator.acknowledgeRemoteMaterialization(
                    pending.revision.revisionID,
                    packageSnapshot: pending.revision.snapshot
                )
                guard workSyncContextIsCurrent(expectedIdentity) else { return false }
                let confirmed = try await client.coordinator.currentState()
                applyWorkSyncState(confirmed, expectedIdentity: expectedIdentity)
                if pending.kind != .remoteFastForward {
                    let publishOutcome = try await client.coordinator.synchronize(
                        at: deviceSyncRuntime?.now() ?? Date()
                    )
                    guard workSyncContextIsCurrent(expectedIdentity) else { return false }
                    applyWorkSyncOutcome(publishOutcome, expectedIdentity: expectedIdentity)
                }
            } else if let staged = state.stagedLocalRevision {
                guard await materializeWorkRevision(staged, expectedIdentity: expectedIdentity) else { return false }
                try await client.coordinator.confirmLocalSnapshotMaterialized(
                    staged.revisionID,
                    packageSnapshot: staged.snapshot
                )
                try await applyWorkSyncState(
                    client.coordinator.currentState(),
                    expectedIdentity: expectedIdentity
                )
            }
            return true
        } catch WorkSyncTransportError.unavailable {
            guard workSyncContextIsCurrent(expectedIdentity) else { return true }
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
            return true
        } catch {
            guard workSyncContextIsCurrent(expectedIdentity) else { return false }
            deviceSyncState = .blocked
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }

    private func materializeWorkRevision(
        _ revision: WorkRevision,
        expectedIdentity: IOSWorkSyncIdentity
    ) async -> Bool {
        guard workSyncContextIsCurrent(expectedIdentity),
              editorCommandSession.isDocumentTransitionPrepared || deviceSyncLocalRecoveryPending,
              let privateWorkingCopyLocation else { return false }
        do {
            let materialized = try revision.snapshot.materializedDocument()
            guard materialized.id == document.id else { return false }
            _ = try privateWorkingCopyLocation.attestPackage(at: documentURL)
            try await repository.save(materialized, to: documentURL)
            _ = try privateWorkingCopyLocation.attestPackage(at: documentURL)
            let loaded = try await repository.load(from: documentURL)
            guard try WorkSnapshot(document: loaded) == revision.snapshot,
                  workSyncContextIsCurrent(expectedIdentity) else { return false }
            document = loaded
            noteDeviceSyncPackageSaved(loaded)
            advanceEditorContentGeneration()
            normalizeSelectionAfterWorkMaterialization()
            saveState = .saved
            deviceSyncLocalDurabilityState = .saved
            return true
        } catch {
            guard workSyncContextIsCurrent(expectedIdentity) else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }

    private func normalizeSelectionAfterWorkMaterialization() {
        if let selectedChapterID,
           document.chapters.contains(where: { $0.id == selectedChapterID }) == false {
            self.selectedChapterID = document.chapters.first?.id
        }
        guard let chapter = selectedChapter else {
            selectedEpisodeID = nil
            return
        }
        if let selectedEpisodeID,
           chapter.episodes.contains(where: { $0.id == selectedEpisodeID }) == false {
            self.selectedEpisodeID = chapter.episodes.first?.id
        } else if selectedEpisodeID == nil {
            selectedEpisodeID = chapter.episodes.first?.id
        }
    }

    func resolveWorkSyncConflict(
        using choice: IOSWorkConflictReviewChoice,
        expectedReview: WorkConflictReview
    ) async {
        guard !workSyncIsApplyingConflict,
              workSyncConflictReview?.id == expectedReview.id,
              let expectedIdentity = activeWorkSyncIdentity else { return }
        workSyncIsApplyingConflict = true
        defer { workSyncIsApplyingConflict = false }
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  workSyncContextIsCurrent(expectedIdentity),
                  workSyncConflictReview?.id == expectedReview.id,
                  let client = workSyncClient,
                  beginDeviceSyncBoundaryTransition() else { return }
            defer { endDeviceSyncBoundaryTransition() }
            guard await saveCurrentWorkSnapshotAtPreparedBoundary() else {
                if workSyncContextIsCurrent(expectedIdentity),
                   workSyncConflictReview?.id == expectedReview.id {
                    keepWorkSyncConflictReviewForRetry(expectedReview)
                }
                return
            }
            guard workSyncContextIsCurrent(expectedIdentity),
                  workSyncConflictReview?.id == expectedReview.id else { return }
            do {
                let currentState = try await client.coordinator.currentState()
                let packageSnapshot = try WorkSnapshot(document: document)
                guard workConflictPackageIsLocallyDurable(
                    packageSnapshot,
                    state: currentState
                ) else {
                    // package保存だけが先行してjournalのstage/confirmが失敗した場合、
                    // このsaveNow自体はpackage成功として完了する。次の明示的な
                    // conflict再試行でexact packageをjournalへ回収できるよう、保存
                    // ループの外側でdirtyを残す（save closure内でmarkすると同じ
                    // saveNowが即時再試行し、失敗表示を利用者へ返せなくなる）。
                    saveCoordinator.markDirty()
                    deviceSyncLocalDurabilityState = .failed
                    keepWorkSyncConflictReviewForRetry(expectedReview)
                    return
                }
                let domainChoice: WorkConflictResolutionChoice = switch choice {
                case .keepLocal: .keepLocal
                case .keepRemote: .keepRemote
                case .useProposed: .useProposed
                }
                let revision: WorkRevision
                if currentState.conflictReview?.id == expectedReview.id {
                    revision = try await client.coordinator.resolveConflict(
                        domainChoice,
                        at: deviceSyncRuntime?.now() ?? Date()
                    )
                } else if let pending = currentState.pendingRemoteMaterialization,
                          pending.kind == .conflictResolution,
                          Set(pending.revision.parentRevisionIDs) == Set([
                              expectedReview.local.revisionID,
                              expectedReview.remote.revisionID
                          ]) {
                    // 前回のchoiceはjournalへ確定済みだが、package保存または
                    // materialization確認だけが失敗した。異なるボタンを押した場合は
                    // 前回choiceを黙って適用せず、exact snapshotが同じ時だけ再開する。
                    guard workConflictSnapshot(
                        for: domainChoice,
                        review: expectedReview
                    ) == pending.revision.snapshot else {
                        keepWorkSyncConflictReviewForPendingChoice(
                            expectedReview,
                            pendingSnapshot: pending.revision.snapshot
                        )
                        return
                    }
                    revision = pending.revision
                } else {
                    applyWorkSyncState(currentState, expectedIdentity: expectedIdentity)
                    return
                }
                guard await materializeWorkRevision(
                    revision,
                    expectedIdentity: expectedIdentity
                ) else {
                    keepWorkSyncConflictReviewForRetry(expectedReview)
                    return
                }
                try await client.coordinator.acknowledgeRemoteMaterialization(
                    revision.revisionID,
                    packageSnapshot: revision.snapshot
                )
                try await applyWorkSyncState(
                    client.coordinator.currentState(),
                    expectedIdentity: expectedIdentity
                )
                _ = await synchronizeWorkSyncAtSafeBoundary(expectedIdentity: expectedIdentity)
            } catch {
                guard workSyncContextIsCurrent(expectedIdentity) else { return }
                keepWorkSyncConflictReviewForRetry(expectedReview)
            }
        }
    }

    private func keepWorkSyncConflictReviewForRetry(_ expectedReview: WorkConflictReview) {
        workSyncConflictReview = expectedReview
        deviceSyncState = .needsReview
        deviceSyncTransferState = .localPending
        operationErrorMessage = "作品の統合版を保存できませんでした。両方の版を保持したまま再試行できます。"
    }

    private func keepWorkSyncConflictReviewForPendingChoice(
        _ expectedReview: WorkConflictReview,
        pendingSnapshot: WorkSnapshot
    ) {
        keepWorkSyncConflictReviewForRetry(expectedReview)
        let pendingTitle = workConflictChoiceTitle(
            for: pendingSnapshot,
            review: expectedReview
        )
        operationErrorMessage = "前回選んだ「\(pendingTitle)」の保存が途中です。別の版へは切り替えず、同じ版を選んで保存を再試行してください。"
    }

    private func workConflictPackageIsLocallyDurable(
        _ packageSnapshot: WorkSnapshot,
        state: WorkSyncState
    ) -> Bool {
        guard state.stagedLocalRevision == nil else { return false }
        if state.localHead.snapshot == packageSnapshot {
            return true
        }
        return state.pendingRemoteMaterialization.map {
            $0.kind == .conflictResolution && $0.revision.snapshot == packageSnapshot
        } == true
    }

    private func workConflictSnapshot(
        for choice: WorkConflictResolutionChoice,
        review: WorkConflictReview
    ) -> WorkSnapshot {
        switch choice {
        case .keepLocal:
            review.local.snapshot
        case .keepRemote:
            review.remote.snapshot
        case .useProposed:
            review.proposedSnapshot
        case let .custom(snapshot):
            snapshot
        }
    }

    private func workConflictChoiceTitle(
        for snapshot: WorkSnapshot,
        review: WorkConflictReview
    ) -> String {
        if snapshot == review.local.snapshot {
            return "このiPhone"
        }
        if snapshot == review.remote.snapshot {
            return "iCloudの版"
        }
        if snapshot == review.proposedSnapshot {
            return "確認用下書き"
        }
        return "前回選んだ版"
    }

    func applyWorkSyncOutcome(
        _ outcome: WorkSyncOutcome,
        expectedIdentity: IOSWorkSyncIdentity
    ) {
        guard workSyncContextIsCurrent(expectedIdentity) else { return }
        switch outcome {
        case .upToDate, .uploaded:
            deviceSyncState = .writer
            deviceSyncTransferState = .upToDate
            workSyncConflictReview = nil
        case .localPending:
            deviceSyncState = .writer
            deviceSyncTransferState = .localPending
        case .offline:
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
        case .remoteFastForward, .automaticallyMerged, .materializationRequired:
            deviceSyncState = .syncing
            deviceSyncTransferState = .localPending
        case let .reviewRequired(review):
            workSyncConflictReview = review
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
        }
    }

    func applyWorkSyncState(
        _ state: WorkSyncState,
        expectedIdentity: IOSWorkSyncIdentity
    ) {
        guard workSyncContextIsCurrent(expectedIdentity) else { return }
        let retainedReview: WorkConflictReview? = if workSyncIsApplyingConflict,
                                                     state.conflictReview == nil,
                                                     state.pendingRemoteMaterialization?.kind == .conflictResolution {
            workSyncConflictReview
        } else {
            nil
        }
        workSyncConflictReview = state.conflictReview ?? retainedReview
        if workSyncConflictReview != nil {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
        } else {
            switch state.reconciliationStatus {
            case .synchronized:
                deviceSyncState = .writer
                deviceSyncTransferState = .upToDate
            case .offline:
                deviceSyncState = .offlineLocal
                deviceSyncTransferState = .localPending
            case .reviewRequired:
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
            case .materializationRequired:
                deviceSyncState = .syncing
                deviceSyncTransferState = .localPending
            case .pending:
                deviceSyncState = .writer
                deviceSyncTransferState = state.pendingRevisionCount > 0 ? .localPending : .notApplicable
            }
        }
    }

    private func continuePackageOnlyAfterWorkSyncPreflightFailure(_ message: String) {
        workSyncClient = nil
        activeWorkSyncIdentity = nil
        workSyncLocalRecoveryReview = nil
        deviceSyncLocalRecoveryPending = false
        deviceSyncState = .blocked
        deviceSyncLocalDurabilityState = .failed
        deviceSyncTransferState = .notApplicable
        operationErrorMessage = message
    }
}
