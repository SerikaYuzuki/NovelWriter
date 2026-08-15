import Foundation
import NovelCore
import NovelSync

enum WorkSyncPackageSavePreparation {
    case notApplicable
    case failed
    case prepared(WorkSyncPreparedPackageSave)
    case notePrepared(NoteSyncPreparedPackageSave)
}

struct WorkSyncPreparedPackageSave {
    let identity: WorkSyncDocumentIdentity
    let client: WorkSyncClient
    let snapshot: WorkSnapshot
    let revisionID: SyncRevisionID
}

struct NoteSyncPreparedPackageSave {
    let identity: WorkSyncDocumentIdentity
    let client: NoteSyncClient
    let snapshot: WorkSnapshot
}

extension AppState {
    var usesWholeWorkSyncRuntime: Bool {
        deviceSyncRuntime?.workTransport != nil
    }

    var currentWorkSyncPreparationIdentity: WorkSyncPreparationIdentity? {
        guard startupState.isReady,
              let structureDigest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return nil }
        return WorkSyncPreparationIdentity(
            documentSession: documentSessionToken,
            structureDigest: structureDigest
        )
    }

    var hasCurrentWorkSyncClient: Bool {
        activeWorkSyncIdentity?.documentSession == documentSessionToken
            && (workSyncClient != nil || noteSyncClient != nil)
    }

    /// `true`はD-061がbinding結果を処理したことを表す。legacy journalだけなら
    /// `false`を返し、同じpreparation task内でD-060へfallbackする。
    func prepareWorkSyncIfAvailable(
        for expectedLookup: DeviceSyncLookupIdentity
    ) async -> Bool {
        await prepareWorkSyncIfAvailable(
            for: WorkSyncPreparationIdentity(
                documentSession: expectedLookup.documentSession,
                structureDigest: expectedLookup.structureDigest
            ),
            resolvedLookup: expectedLookup
        )
    }

    /// Episode選択に依存しない作品単位のsingle-flight preflight。
    /// 章だけで話が0件の作品でも、編集を解放する前にbindingとwork journalを読む。
    func prepareWholeWorkSync(for expectedIdentity: WorkSyncPreparationIdentity) async {
        while let inFlight = workSyncPreparationTask {
            let observedGeneration = workSyncPreparationGeneration
            let observedIdentity = workSyncPreparationIdentity
            if observedIdentity != expectedIdentity {
                inFlight.cancel()
                workSyncPreparationGeneration &+= 1
                workSyncPreparationTask = nil
                workSyncPreparationIdentity = nil
                break
            }
            await inFlight.value
            if workSyncPreparationGeneration == observedGeneration {
                workSyncPreparationTask = nil
                workSyncPreparationIdentity = nil
            }
            guard currentWorkSyncPreparationIdentity == expectedIdentity else { return }
            return
        }

        workSyncPreparationGeneration &+= 1
        let generation = workSyncPreparationGeneration
        let preparation = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            let handled = await prepareWorkSyncIfAvailable(
                for: expectedIdentity,
                resolvedLookup: nil
            )
            guard currentWorkSyncPreparationIdentity == expectedIdentity else { return }
            if !handled {
                // legacy Episode bindingだけの作品にはwhole-work evidenceがない。
                // 偽のEpisode IDでD-060を開始せず、端末packageだけを継続する。
                deviceSyncLocalRecoveryPending = false
                resolvedDeviceSyncLookupIdentity = nil
                deviceSyncState = .unconfigured
                deviceSyncSetupState = .idle
                deviceSyncTransferState = .notApplicable
                deviceSyncLocalDurabilityState = .notApplicable
            }
        }
        workSyncPreparationTask = preparation
        workSyncPreparationIdentity = expectedIdentity
        await preparation.value
        if workSyncPreparationGeneration == generation {
            workSyncPreparationTask = nil
            workSyncPreparationIdentity = nil
        }
    }

    private func prepareWorkSyncIfAvailable(
        for expectedIdentity: WorkSyncPreparationIdentity,
        resolvedLookup expectedLookup: DeviceSyncLookupIdentity?
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime else { return false }
        if runtime.makeNoteSyncCoordinator != nil {
            return await prepareNoteSyncIfAvailable(
                for: expectedIdentity,
                resolvedLookup: expectedLookup
            )
        }
        guard let transport = runtime.workTransport else { return false }
        startDeviceSyncSignalObservationIfNeeded()
        guard currentWorkSyncPreparationIdentity == expectedIdentity else { return true }

        if let identity = activeWorkSyncIdentity,
           identity.documentSession == expectedIdentity.documentSession,
           workSyncClient != nil {
            if deviceSyncLocalRecoveryPending || workSyncLocalRecoveryReview != nil {
                // 同じpreflightを途中からshortcutしてEditor gateを解除しない。
                return true
            }
            if let expectedLookup,
               resolvedDeviceSyncLookupIdentity != expectedLookup {
                return true
            }
            return true
        }

        deviceSyncState = .syncing
        // binding/account確認はlocal原稿の安全性を変えない。通信待ちだけを理由に
        // Editorを止めず、journalを読むprepared境界へ入る直前だけgateする。
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
            // bindingの失敗にはremote account確認失敗も含まれる。package保存だけで
            // 執筆を続けられるため、networkをEditor gateにはしない。
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
        guard let journal = resolution.workJournal else {
            // D-060の既存bindingを壊さないadditive cutover。
            deviceSyncLocalRecoveryPending = true
            return false
        }
        let descriptorMatches = resolution.descriptor == nil
            || resolution.descriptor?.workID == resolution.binding.workID
            && resolution.descriptor?.sourceDocumentID == document.id
        let remoteAvailability = descriptorMatches
            ? resolution.remoteAvailability
            : .configurationBlocked

        let identity = WorkSyncDocumentIdentity(
            documentSession: expectedIdentity.documentSession,
            workID: resolution.binding.workID,
            localWorkingCopyID: resolution.binding.localWorkingCopyID
        )
        let client: WorkSyncClient
        if activeWorkSyncIdentity == identity, let existing = workSyncClient {
            client = WorkSyncClient(
                coordinator: existing.coordinator,
                sessionID: existing.sessionID,
                remoteAvailability: remoteAvailability
            )
        } else {
            let sessionID = SyncEditSessionID()
            client = WorkSyncClient(
                coordinator: WorkSyncCoordinator(
                    workID: identity.workID,
                    localWorkingCopyID: identity.localWorkingCopyID,
                    replicaID: runtime.replicaID,
                    sessionID: sessionID,
                    transport: transport,
                    journal: journal
                ),
                sessionID: sessionID,
                remoteAvailability: remoteAvailability
            )
        }
        deviceSyncSetupState = descriptorMatches
            ? .configured
            : .unavailable(message: "作品の同期情報が一致しません")
        await prepareResolvedWorkSync(
            identity: identity,
            client: client,
            expectedIdentity: expectedIdentity,
            resolvedLookup: expectedLookup,
            descriptorMatches: descriptorMatches,
            runtime: runtime
        )
        return true
    }

    private func prepareResolvedWorkSync(
        identity: WorkSyncDocumentIdentity,
        client: WorkSyncClient,
        expectedIdentity: WorkSyncPreparationIdentity,
        resolvedLookup expectedLookup: DeviceSyncLookupIdentity?,
        descriptorMatches: Bool,
        runtime: DeviceSyncRuntime
    ) async {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentWorkSyncPreparationIdentity == expectedIdentity else { return }
            deviceSyncLocalRecoveryPending = true
            guard beginDocumentTransition() else {
                deviceSyncLocalRecoveryPending = false
                return
            }
            defer { endDocumentTransition() }

            do {
                // clientを公開する前にlocal journalを読み切る。restore中の話切替が
                // 「準備済みclient」shortcutとしてEditorを開ける余地を作らない。
                let restored = try await client.coordinator.restore()
                guard documentSessionToken == identity.documentSession else { return }
                activeWorkSyncIdentity = identity
                workSyncClient = client
                isCurrentWorkBoundToCloud = true

                // makeFirstResponder(nil)／EditorKit prepare後の最新本文・フォーム値を
                // 二相保存し、それを保存層から読み戻してからだけreconcileする。
                guard await captureAndSaveActiveWorkSyncEditorIfNeeded(),
                      let packageSnapshot = await readCurrentWorkSyncPackageSnapshotAtPreparedBoundary(
                          expectedSession: identity.documentSession
                      ),
                      try packageSnapshot == WorkSnapshot(document: document) else {
                    deviceSyncLocalDurabilityState = .failed
                    deviceSyncLocalRecoveryPending = true
                    return
                }

                if restored == nil {
                    _ = try await client.coordinator.bootstrapLocalSnapshot(
                        packageSnapshot,
                        at: runtime.now()
                    )
                    deviceSyncTransferState = .localPending
                } else {
                    let recovery = try await client.coordinator.reconcileLocalMaterialization(
                        packageSnapshot: packageSnapshot,
                        at: runtime.now()
                    )
                    guard workSyncContextIsCurrent(identity),
                          await applyWorkSyncRecovery(
                              recovery,
                              identity: identity,
                              client: client
                          ) else { return }
                }

                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncLocalDurabilityState = .saved
                deviceSyncLocalRecoveryPending = false
                resolvedDeviceSyncLookupIdentity = currentDeviceSyncLookupIdentity ?? expectedLookup
                let state = try await client.coordinator.currentState()
                if state.conflictReview != nil || state.reconciliationStatus == .reviewRequired {
                    await markLibraryNeedsReview(identity)
                }
                applyWorkSyncState(state, client: client)
                if !descriptorMatches {
                    deviceSyncState = .blocked
                }
                if client.remoteSynchronizationAllowed {
                    scheduleWorkSyncNetwork(identity: identity, client: client)
                } else {
                    scheduleWorkSyncRemoteBindingRefresh(identity: identity)
                }
            } catch {
                guard documentSessionToken == identity.documentSession else { return }
                deviceSyncState = .blocked
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                deviceSyncLocalRecoveryPending = true
            }
        }
    }

    func stageWorkSyncPackageSave(
        _ document: NovelDocument
    ) async -> WorkSyncPackageSavePreparation {
        if usesNoteSyncRuntime {
            return await stageNoteSyncPackageSave(document)
        }
        guard let runtime = deviceSyncRuntime,
              runtime.workTransport != nil,
              let identity = activeWorkSyncIdentity,
              let client = workSyncClient,
              workSyncContextIsCurrent(identity) else {
            return .notApplicable
        }
        do {
            let snapshot = try WorkSnapshot(document: document)
            let revision = try await client.coordinator.stageLocalSnapshot(
                snapshot,
                at: runtime.now()
            )
            guard workSyncContextIsCurrent(identity) else { return .failed }
            deviceSyncLocalDurabilityState = .pending
            deviceSyncTransferState = .localPending
            return .prepared(
                WorkSyncPreparedPackageSave(
                    identity: identity,
                    client: client,
                    snapshot: snapshot,
                    revisionID: revision.revisionID
                )
            )
        } catch {
            guard workSyncContextIsCurrent(identity) else { return .failed }
            // package保存はこのあと必ず試す。ここでは端末保存失敗をclaimしない。
            deviceSyncLocalDurabilityState = .pending
            return .failed
        }
    }

    func confirmWorkSyncPackageSave(
        _ preparation: WorkSyncPreparedPackageSave
    ) async {
        guard workSyncContextIsCurrent(preparation.identity) else { return }
        do {
            let state = try await preparation.client.coordinator.currentState()
            if state.stagedLocalRevision?.revisionID == preparation.revisionID {
                try await preparation.client.coordinator.confirmLocalSnapshotMaterialized(
                    preparation.revisionID,
                    packageSnapshot: preparation.snapshot
                )
            }
            guard workSyncContextIsCurrent(preparation.identity) else { return }
            deviceSyncLocalDurabilityState = .saved
            let confirmedState = try await preparation.client.coordinator.currentState()
            applyWorkSyncState(confirmedState, client: preparation.client)
            scheduleWorkSyncNetwork(identity: preparation.identity, client: preparation.client)
        } catch {
            guard workSyncContextIsCurrent(preparation.identity) else { return }
            // packageは既にatomic save済み。journal markerを残し、次回preflightで照合する。
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            deviceSyncTransferState = .localPending
        }
    }

    func applyWorkSyncRecovery(
        _ recovery: WorkLocalRecoveryOutcome,
        identity: WorkSyncDocumentIdentity,
        client: WorkSyncClient
    ) async -> Bool {
        switch recovery {
        case .consistent, .confirmedStaged, .acknowledgedRemote, .capturedUnstagedPackage:
            workSyncLocalRecoveryReview = nil
            return true
        case let .materializeStaged(revision):
            if editorCommandSession.isDocumentTransitionPrepared {
                return await materializeWorkSyncRevisionAtPreparedBoundary(
                    revision,
                    identity: identity,
                    client: client,
                    confirmation: .localStage
                )
            }
            return await materializeWorkSyncRevision(
                revision,
                identity: identity,
                client: client,
                confirmation: .localStage
            )
        case let .materializeRemote(pending):
            if editorCommandSession.isDocumentTransitionPrepared {
                return await materializeWorkSyncRevisionAtPreparedBoundary(
                    pending.revision,
                    identity: identity,
                    client: client,
                    confirmation: .remote
                )
            }
            return await materializeWorkSyncRevision(
                pending.revision,
                identity: identity,
                client: client,
                confirmation: .remote
            )
        case let .reviewRequired(review):
            workSyncLocalRecoveryReview = review
            await markLibraryNeedsReview(identity)
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            // preflightの複数版を選ぶまでEditorを開かない。
            deviceSyncLocalRecoveryPending = true
            return false
        }
    }

    enum WorkSyncMaterializationConfirmation {
        case localStage
        case remote
    }

    func materializePendingWorkSyncAtPreparedBoundary() async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared,
              let identity = activeWorkSyncIdentity,
              let client = workSyncClient,
              workSyncContextIsCurrent(identity) else { return true }
        let state: WorkSyncState
        do {
            state = try await client.coordinator.currentState()
        } catch {
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            return false
        }
        guard let pending = state.pendingRemoteMaterialization else {
            applyWorkSyncState(state, client: client)
            return true
        }
        return await materializeWorkSyncRevisionAtPreparedBoundary(
            pending.revision,
            identity: identity,
            client: client,
            confirmation: .remote
        )
    }

    func resolveWorkSyncConflict(
        using choice: WorkConflictReviewChoice,
        expectedReview: WorkConflictReview,
        expectedSession: DocumentSessionToken
    ) async {
        guard !isApplyingWorkSyncConflict,
              documentSessionToken == expectedSession,
              workSyncConflictReview == expectedReview,
              let identity = activeWorkSyncIdentity,
              let client = workSyncClient,
              workSyncContextIsCurrent(identity) else { return }
        let domainChoice: WorkConflictResolutionChoice = switch choice {
        case .keepLocal: .keepLocal
        case .keepRemote: .keepRemote
        case .useProposed: .useProposed
        }
        isApplyingWorkSyncConflict = true
        defer { isApplyingWorkSyncConflict = false }

        await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  workSyncContextIsCurrent(identity),
                  beginDocumentTransition() else { return }
            defer { endDocumentTransition() }

            guard await prepareExactPackageForWorkConflictChoice(
                expectedReview: expectedReview,
                identity: identity,
                client: client
            ) else { return }
            do {
                let revision = try await client.coordinator.resolveConflict(
                    domainChoice,
                    at: deviceSyncRuntime?.now() ?? Date()
                )
                guard workSyncContextIsCurrent(identity) else { return }
                // choiceはjournalのpending materializationとして既にdurable。package
                // 保存が失敗しても旧3択を再表示せず、この選択だけを次の安全境界で
                // 再試行する。旧sheetから逆choiceが届いてもouter guardで拒否する。
                workSyncConflictReview = nil
                deviceSyncState = .syncing
                deviceSyncTransferState = .localPending
                let installed = await materializeWorkSyncRevisionAtPreparedBoundary(
                    revision,
                    identity: identity,
                    client: client,
                    confirmation: .remote
                )
                guard installed, workSyncContextIsCurrent(identity) else { return }
                scheduleWorkSyncNetwork(identity: identity, client: client)
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
            }
        }
    }

    private func prepareExactPackageForWorkConflictChoice(
        expectedReview: WorkConflictReview,
        identity: WorkSyncDocumentIdentity,
        client: WorkSyncClient
    ) async -> Bool {
        // Sheet表示後の入力も先にstage→package→confirmへ流す。stage/confirmの
        // どちらかが落ちても、packageだけ先行した版をexactにreconcileできるまで
        // 旧reviewのchoiceを適用しない。
        guard await captureAndSaveActiveWorkSyncEditorIfNeeded(),
              workSyncContextIsCurrent(identity),
              let memorySnapshot = try? WorkSnapshot(document: document),
              let packageSnapshot = await readCurrentWorkSyncPackageSnapshotAtPreparedBoundary(
                  expectedSession: identity.documentSession
              ),
              packageSnapshot == memorySnapshot else {
            deviceSyncLocalDurabilityState = .failed
            return false
        }
        do {
            let recovery = try await client.coordinator.reconcileLocalMaterialization(
                packageSnapshot: packageSnapshot,
                at: deviceSyncRuntime?.now() ?? Date()
            )
            switch recovery {
            case .consistent, .confirmedStaged, .acknowledgedRemote, .capturedUnstagedPackage:
                break
            case let .reviewRequired(review):
                workSyncLocalRecoveryReview = review
                deviceSyncLocalRecoveryPending = true
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
                return false
            case .materializeStaged, .materializeRemote:
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
                return false
            }

            let currentState = try await client.coordinator.currentState()
            applyWorkSyncState(currentState, client: client)
            guard currentState.stagedLocalRevision == nil,
                  currentState.pendingRemoteMaterialization == nil,
                  currentState.localHead.snapshot == packageSnapshot else {
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                return false
            }
            deviceSyncLocalDurabilityState = .saved
            guard currentState.conflictReview == expectedReview,
                  workSyncConflictReview == expectedReview else {
                // local tailを取り込んだ新しいreviewを表示し直し、再選択を求める。
                return false
            }
            return true
        } catch {
            guard workSyncContextIsCurrent(identity) else { return false }
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return false
        }
    }

    func resolveWorkSyncLocalRecovery(
        using choice: WorkConflictReviewChoice,
        expectedReview: WorkLocalRecoveryReview,
        expectedSession: DocumentSessionToken
    ) async {
        guard !isApplyingWorkSyncConflict,
              documentSessionToken == expectedSession,
              workSyncLocalRecoveryReview == expectedReview,
              let identity = activeWorkSyncIdentity,
              let client = workSyncClient,
              workSyncContextIsCurrent(identity) else { return }
        let recoveryChoice: WorkLocalRecoveryChoice
        switch choice {
        case .keepLocal:
            recoveryChoice = .keepObservedPackage
        case .keepRemote:
            if expectedReview.stagedLocalRevision != nil {
                recoveryChoice = .materializeStaged
            } else if expectedReview.pendingRemoteMaterialization != nil {
                recoveryChoice = .materializePendingRemote
            } else {
                return
            }
        case .useProposed:
            guard expectedReview.stagedLocalRevision != nil,
                  expectedReview.pendingRemoteMaterialization != nil else { return }
            recoveryChoice = .materializePendingRemote
        }

        isApplyingWorkSyncConflict = true
        defer { isApplyingWorkSyncConflict = false }
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  workSyncContextIsCurrent(identity),
                  workSyncLocalRecoveryReview == expectedReview,
                  beginDocumentTransition() else { return }
            defer { endDocumentTransition() }
            do {
                let observed = try WorkSnapshot(document: document)
                guard observed == expectedReview.observedPackageSnapshot else { return }
                let outcome = try await client.coordinator.resolveLocalRecovery(
                    recoveryChoice,
                    observedPackageSnapshot: observed,
                    at: deviceSyncRuntime?.now() ?? Date()
                )
                guard workSyncContextIsCurrent(identity) else { return }
                let resolved: Bool
                switch outcome {
                case let .materializeStaged(revision):
                    resolved = await materializeWorkSyncRevisionAtPreparedBoundary(
                        revision,
                        identity: identity,
                        client: client,
                        confirmation: .localStage
                    )
                case let .materializeRemote(pending):
                    resolved = await materializeWorkSyncRevisionAtPreparedBoundary(
                        pending.revision,
                        identity: identity,
                        client: client,
                        confirmation: .remote
                    )
                case .consistent, .confirmedStaged, .acknowledgedRemote, .capturedUnstagedPackage:
                    resolved = true
                case let .reviewRequired(updated):
                    workSyncLocalRecoveryReview = updated
                    resolved = false
                }
                guard resolved, workSyncContextIsCurrent(identity) else { return }
                workSyncLocalRecoveryReview = nil
                deviceSyncLocalRecoveryPending = false
                deviceSyncLocalDurabilityState = .saved
                let state = try await client.coordinator.currentState()
                applyWorkSyncState(state, client: client)
                if client.remoteSynchronizationAllowed {
                    scheduleWorkSyncNetwork(identity: identity, client: client)
                } else {
                    scheduleWorkSyncRemoteBindingRefresh(identity: identity)
                }
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
                deviceSyncLocalRecoveryPending = true
            }
        }
    }

    private func materializeWorkSyncRevision(
        _ revision: WorkRevision,
        identity: WorkSyncDocumentIdentity,
        client: WorkSyncClient,
        confirmation: WorkSyncMaterializationConfirmation
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  workSyncContextIsCurrent(identity),
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            return await materializeWorkSyncRevisionAtPreparedBoundary(
                revision,
                identity: identity,
                client: client,
                confirmation: confirmation
            )
        }
    }

    private func materializeWorkSyncRevisionAtPreparedBoundary(
        _ revision: WorkRevision,
        identity: WorkSyncDocumentIdentity,
        client: WorkSyncClient,
        confirmation: WorkSyncMaterializationConfirmation
    ) async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared,
              workSyncContextIsCurrent(identity),
              revision.workID == identity.workID else { return false }
        let installed = await persistAndInstallWorkSyncSnapshot(
            revision.snapshot,
            expectedSession: identity.documentSession
        )
        guard installed else {
            if workSyncContextIsCurrent(identity) {
                deviceSyncLocalDurabilityState = .failed
            }
            return false
        }
        guard workSyncContextIsCurrent(identity) else { return false }
        do {
            switch confirmation {
            case .localStage:
                try await client.coordinator.confirmLocalSnapshotMaterialized(
                    revision.revisionID,
                    packageSnapshot: revision.snapshot
                )
            case .remote:
                try await client.coordinator.acknowledgeRemoteMaterialization(
                    revision.revisionID,
                    packageSnapshot: revision.snapshot
                )
            }
            guard workSyncContextIsCurrent(identity) else { return false }
            workSyncLocalRecoveryReview = nil
            deviceSyncLocalDurabilityState = .saved
            let state = try await client.coordinator.currentState()
            applyWorkSyncState(state, client: client)
            if case .remote = confirmation {
                scheduleWorkSyncNetwork(identity: identity, client: client)
            }
            return true
        } catch {
            // packageはrevisionと一致している。ack markerはrestart preflightが再確認する。
            deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
            return true
        }
    }

    func captureAndSaveActiveWorkSyncEditorIfNeeded() async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared else { return false }
        if let chapterID = selectedChapterID, let episodeID = selectedEpisodeID {
            switch captureCommittedTextForDeviceSync() {
            case let .captured(content):
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
        }
        return await saveCoordinator.saveNow()
    }

    func refreshWholeWorkSync() async {
        guard let runtime = deviceSyncRuntime,
              let identity = activeWorkSyncIdentity,
              workSyncContextIsCurrent(identity) else { return }
        if noteSyncClient != nil {
            // D-073: foreground / push ではNote send／pullしない。明示同期だけが送る。
            return
        }
        guard let client = workSyncClient else { return }
        do {
            let structureDigest = try SyncWorkStructureDigest(chapters: document.chapters)
            let resolution = try await runtime.binding(identity.documentSession, structureDigest)
            guard workSyncContextIsCurrent(identity) else { return }
            let localIdentityMatches = resolution.map {
                $0.binding.workID == identity.workID
                    && $0.binding.localWorkingCopyID == identity.localWorkingCopyID
                    && $0.workJournal != nil
            } == true
            let descriptorMatches = resolution.map {
                $0.descriptor == nil
                    || $0.descriptor?.workID == identity.workID
                    && $0.descriptor?.sourceDocumentID == document.id
            } == true
            let availability = localIdentityMatches && descriptorMatches
                ? resolution?.remoteAvailability ?? .configurationBlocked
                : .configurationBlocked
            let refreshed = WorkSyncClient(
                coordinator: client.coordinator,
                sessionID: client.sessionID,
                remoteAvailability: availability
            )
            workSyncClient = refreshed
            if refreshed.remoteSynchronizationAllowed {
                scheduleWorkSyncNetwork(identity: identity, client: refreshed)
            } else {
                deviceSyncState = availability == .temporarilyOffline ? .offlineLocal : .blocked
            }
        } catch {
            guard workSyncContextIsCurrent(identity) else { return }
            deviceSyncState = .offlineLocal
        }
    }

    func scheduleWorkSyncRemoteBindingRefresh(identity: WorkSyncDocumentIdentity) {
        guard workSyncContextIsCurrent(identity),
              workSyncRemoteBindingTask == nil else { return }
        workSyncRemoteBindingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshWholeWorkSync()
            if workSyncContextIsCurrent(identity) {
                workSyncRemoteBindingTask = nil
            }
        }
    }

    func scheduleWorkSyncNetwork(
        identity: WorkSyncDocumentIdentity,
        client: WorkSyncClient,
        remainingTailRetries: Int = 4
    ) {
        guard workSyncContextIsCurrent(identity),
              client.remoteSynchronizationAllowed,
              workSyncConflictReview == nil,
              workSyncLocalRecoveryReview == nil else { return }
        if workSyncNetworkTask != nil {
            // save confirm／foreground refreshが通信中に来ても、完了直後の一回へ
            // coalesceして取りこぼさない。
            workSyncNetworkRescheduleRequested = true
            return
        }
        deviceSyncTransferState = .uploading
        workSyncNetworkTask = Task { @MainActor [weak self] in
            guard let self, let runtime = deviceSyncRuntime else { return }
            var mayRetryFreshTail = false
            do {
                let outcome = try await client.coordinator.synchronize(at: runtime.now())
                guard workSyncContextIsCurrent(identity) else { return }
                await applyWorkSyncOutcome(outcome, identity: identity, client: client)
                switch outcome {
                case .upToDate, .uploaded, .localPending:
                    mayRetryFreshTail = true
                case .offline, .remoteFastForward, .automaticallyMerged,
                     .reviewRequired, .materializationRequired:
                    break
                }
            } catch WorkSyncTransportError.unavailable {
                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .offlineLocal
                deviceSyncTransferState = .localPending
            } catch {
                guard workSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .blocked
                deviceSyncTransferState = .localPending
            }
            let explicitlyRequested = workSyncNetworkRescheduleRequested
            workSyncNetworkRescheduleRequested = false
            if workSyncContextIsCurrent(identity) {
                workSyncNetworkTask = nil
            }
            guard explicitlyRequested || mayRetryFreshTail,
                  explicitlyRequested || remainingTailRetries > 0,
                  workSyncContextIsCurrent(identity) else { return }
            let retryAttempt = max(0, 4 - remainingTailRetries)
            let retryDelayMilliseconds = explicitlyRequested
                ? 25
                : min(800, 25 * (1 << min(retryAttempt, 5)))
            try? await Task.sleep(for: .milliseconds(retryDelayMilliseconds))
            guard workSyncContextIsCurrent(identity),
                  workSyncNetworkTask == nil,
                  let fresh = try? await client.coordinator.currentState(),
                  fresh.stagedLocalRevision == nil,
                  fresh.pendingRemoteMaterialization == nil,
                  fresh.conflictReview == nil else { return }
            guard explicitlyRequested || fresh.pendingRevisionCount > 0 else { return }
            scheduleWorkSyncNetwork(
                identity: identity,
                client: client,
                remainingTailRetries: explicitlyRequested
                    ? remainingTailRetries
                    : remainingTailRetries - 1
            )
        }
    }

    func applyWorkSyncOutcome(
        _ outcome: WorkSyncOutcome,
        identity: WorkSyncDocumentIdentity,
        client _: WorkSyncClient
    ) async {
        guard workSyncContextIsCurrent(identity) else { return }
        switch outcome {
        case let .upToDate(revision), let .uploaded(revision):
            guard await acknowledgeLibraryRemoteHead(revision, identity: identity) else {
                deviceSyncState = .syncing
                deviceSyncTransferState = .localPending
                deviceSyncLocalDurabilityState = .savedSyncPreparationFailed
                return
            }
            workSyncConflictReview = nil
            deviceSyncState = .writer
            deviceSyncTransferState = .upToDate
        case .offline:
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
        case .localPending, .remoteFastForward, .automaticallyMerged, .materializationRequired:
            // Domain journalへdurable staging済み。active Editorへは流し込まず、
            // 次のprepared departureでpackage全体をatomic materializeする。
            deviceSyncState = .syncing
            deviceSyncTransferState = .localPending
        case let .reviewRequired(review):
            workSyncConflictReview = review
            await markLibraryNeedsReview(identity)
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
        }
    }

    private func acknowledgeLibraryRemoteHead(
        _ revision: WorkRevision,
        identity: WorkSyncDocumentIdentity
    ) async -> Bool {
        guard revision.workID == identity.workID else { return false }
        guard let library = deviceSyncRuntime?.library else { return true }
        do {
            let entry = try SyncWorkLibraryEntry(head: revision)
            try await library.markSynced(identity.workID, entry)
            return true
        } catch {
            return false
        }
    }

    func markLibraryNeedsReview(_ identity: WorkSyncDocumentIdentity) async {
        guard workSyncContextIsCurrent(identity),
              let library = deviceSyncRuntime?.library else { return }
        try? await library.markNeedsReview(identity.workID)
    }

    func applyWorkSyncState(_ state: WorkSyncState, client: WorkSyncClient) {
        workSyncConflictReview = state.conflictReview
        if state.conflictReview != nil {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return
        }
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
        case .materializationRequired, .pending:
            deviceSyncState = client.remoteSynchronizationAllowed ? .syncing : .offlineLocal
            deviceSyncTransferState = .localPending
        }
    }

    func workSyncContextIsCurrent(_ identity: WorkSyncDocumentIdentity) -> Bool {
        activeWorkSyncIdentity == identity && documentSessionToken == identity.documentSession
    }

    func clearWorkSyncClient() {
        workSyncNetworkTask?.cancel()
        workSyncNetworkTask = nil
        workSyncNetworkRescheduleRequested = false
        workSyncRemoteBindingTask?.cancel()
        workSyncRemoteBindingTask = nil
        activeWorkSyncIdentity = nil
        workSyncClient = nil
        noteSyncClient = nil
        isCurrentWorkBoundToCloud = false
        noteSyncConflict = nil
        workSyncConflictReview = nil
        workSyncLocalRecoveryReview = nil
        isApplyingWorkSyncConflict = false
    }
}
