import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    var currentDeviceSyncLookupIdentity: DeviceSyncLookupIdentity? {
        guard startupState.isReady,
              let selectedChapterID,
              let selectedEpisodeID,
              let structureDigest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return nil }
        return DeviceSyncLookupIdentity(
            documentSession: documentSessionToken,
            chapterID: selectedChapterID,
            episodeID: selectedEpisodeID,
            editorContentGeneration: editorContentGeneration,
            structureDigest: structureDigest
        )
    }

    func deviceSyncAllowsEditing(for lookup: DeviceSyncLookupIdentity) -> Bool {
        guard !deviceSyncStartupFailedSafely, startupState.isReady else { return false }
        guard deviceSyncRuntime != nil else { return true }
        guard resolvedDeviceSyncLookupIdentity == lookup else { return false }
        return deviceSyncState.allowsEditing
    }

    func deviceSyncSelectionDidChange() {
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil
        activeDeviceSyncIdentity = nil
        resolvedDeviceSyncLookupIdentity = nil
        pendingDeviceSyncConflictResolution = nil
        deviceSyncConflict = nil
        deviceSyncState = deviceSyncRuntime == nil ? .unconfigured : .syncing
        deviceSyncTransferState = .notApplicable
        if case .candidates = deviceSyncSetupState {
            deviceSyncSetupState = .idle
        }
        if pendingDeviceSyncNewWork?.session != documentSessionToken {
            pendingDeviceSyncNewWork = nil
        }
    }

    func prepareDeviceSync(for expectedLookup: DeviceSyncLookupIdentity) async {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        startDeviceSyncSignalObservationIfNeeded()
        if resolvedDeviceSyncLookupIdentity == expectedLookup,
           activeDeviceSyncIdentity?.documentSession == expectedLookup.documentSession || deviceSyncRuntime == nil
        {
            return
        }
        guard let runtime = deviceSyncRuntime else {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .unconfigured
            deviceSyncSetupState = .idle
            return
        }
        deviceSyncState = .syncing
        resolvedDeviceSyncLookupIdentity = nil
        activeDeviceSyncIdentity = nil

        let resolution: DeviceSyncBindingResolution?
        do {
            resolution = try await runtime.binding(
                expectedLookup.documentSession,
                expectedLookup.structureDigest
            )
        } catch {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期の接続を確認できません")
            return
        }

        guard !Task.isCancelled,
              currentDeviceSyncLookupIdentity == expectedLookup else { return }
        guard let resolution else {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .unconfigured
            deviceSyncSetupState = .idle
            return
        }
        deviceSyncSetupState = .configured
        let binding = resolution.binding
        guard resolution.descriptor.workID == binding.workID,
              resolution.descriptor.sourceDocumentID == document.id else {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "作品の同期情報が一致しません")
            return
        }
        guard resolution.allowedEpisodeIDs.contains(expectedLookup.episodeID) else {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            activeDeviceSyncIdentity = nil
            deviceSyncState = .episodeNotIncluded
            return
        }

        let syncKey = EpisodeSyncKey(workID: binding.workID, episodeID: expectedLookup.episodeID)
        let clientKey = DeviceSyncClientKey(
            localWorkingCopyID: binding.localWorkingCopyID,
            syncKey: syncKey
        )
        let client: DeviceSyncClient
        let isNewClient: Bool
        if let existing = deviceSyncClients[clientKey] {
            client = existing
            isNewClient = false
        } else {
            let sessionID = SyncEditSessionID()
            client = DeviceSyncClient(
                coordinator: EpisodeSyncCoordinator(
                    key: syncKey,
                    replicaID: runtime.replicaID,
                    sessionID: sessionID,
                    transport: runtime.transport,
                    journal: resolution.journal
                ),
                sessionID: sessionID
            )
            deviceSyncClients[clientKey] = client
            isNewClient = true
        }

        var identity = DeviceSyncEpisodeIdentity(
            documentSession: expectedLookup.documentSession,
            chapterID: expectedLookup.chapterID,
            episodeID: expectedLookup.episodeID,
            editorContentGeneration: expectedLookup.editorContentGeneration,
            structureDigest: expectedLookup.structureDigest,
            localWorkingCopyID: binding.localWorkingCopyID,
            syncKey: syncKey
        )
        activeDeviceSyncIdentity = identity
        resolvedDeviceSyncLookupIdentity = expectedLookup

        var authorityVerifiedForActivation = false
        do {
            var state = isNewClient ? try await client.coordinator.restore() : await client.coordinator.state
            guard deviceSyncContextIsCurrent(identity) else { return }
            if isNewClient, case .restoredUnverified = state {
                // sealed mutation/receiptだけをfresh processでreplayする。unsealed pendingは
                // domain側がread-onlyに保ち、次sessionのclaim成功前にはpublishしない。
                state = try await client.coordinator.synchronize()
                guard deviceSyncContextIsCurrent(identity) else { return }
            }
            guard let recoveredIdentity = await recoverAcceptedMergeIfNeeded(
                state: state,
                client: client,
                expectedIdentity: identity,
                runtime: runtime
            ) else { return }
            identity = recoveredIdentity
            state = await client.coordinator.state
            if case let .conflicted(_, conflict) = state {
                guard await preserveUnjournaledConflictDraftIfNeeded(
                    conflict,
                    client: client,
                    expectedIdentity: identity,
                    runtime: runtime
                ) else {
                    deviceSyncState = .blocked
                    return
                }
                state = await client.coordinator.state
                applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                return
            }
            if case .unlinked = state {
                // 初回linkは下で行う。
            } else if case .authorityGrantedAwaitingInstall = state {
                // すでに得たexact grantは下のinstall経路で確定する。
            } else if !ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime) {
                // fresh processだけでなく、同じprocessで正常release済みの
                // clientも破壊的forceではなく通常claimを先に試す。
                state = try await client.coordinator.claimEditingAuthority(
                    expiresAt: runtime.leaseExpiration()
                )
                guard deviceSyncContextIsCurrent(identity) else {
                    await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                    return
                }
                authorityVerifiedForActivation = ownsDeviceSyncAuthority(
                    in: state,
                    client: client,
                    runtime: runtime
                )
                if !authorityVerifiedForActivation,
                   case .authorityGrantedAwaitingInstall = state
                {
                    // exact grantは下の共通install経路へ渡す。
                } else if !authorityVerifiedForActivation {
                    let observation = try await client.coordinator.inspectFence()
                    guard deviceSyncContextIsCurrent(identity) else { return }
                    await installFenceObservation(observation, client: client, expectedIdentity: identity)
                    return
                }
            } else {
                // このsessionが保持しているauthorityは、編集を許す前に
                // exact fenceを必ず再検査する。
                let observation = try await client.coordinator.inspectFence()
                guard deviceSyncContextIsCurrent(identity) else { return }
                switch observation {
                case .authorityValid:
                    authorityVerifiedForActivation = true
                    state = await client.coordinator.state
                case .authorityLost, .remoteAdvanced:
                    await installFenceObservation(observation, client: client, expectedIdentity: identity)
                    return
                }
            }
            if case .unlinked = state {
                let localContent = document.episode(identity.episodeID)?.episode.content ?? ""
                state = try await client.coordinator.link(
                    localContent: localContent,
                    createdAt: runtime.now(),
                    leaseExpiresAt: runtime.leaseExpiration()
                )
                authorityVerifiedForActivation = ownsDeviceSyncAuthority(
                    in: state,
                    client: client,
                    runtime: runtime
                )
            }
            guard deviceSyncContextIsCurrent(identity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            if case .authorityGrantedAwaitingInstall = state {
                // install ack前に再claimしない。
            } else if !ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime) {
                state = try await client.coordinator.claimEditingAuthority(
                    expiresAt: runtime.leaseExpiration()
                )
                authorityVerifiedForActivation = ownsDeviceSyncAuthority(
                    in: state,
                    client: client,
                    runtime: runtime
                )
            }
            guard deviceSyncContextIsCurrent(identity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            if ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime),
               case .localChanges = state
            {
                let packageContent = document.episode(identity.episodeID)?.episode.content ?? ""
                if let context = deviceSyncContext(from: state),
                   context.localHead.contentDigest != SyncContentDigest(content: packageContent)
                {
                    state = try await client.coordinator.recordLocalContent(
                        packageContent,
                        createdAt: runtime.now()
                    )
                }
                state = try await client.coordinator.synchronize()
                guard deviceSyncContextIsCurrent(identity) else { return }
            }
            if case let .authorityGrantedAwaitingInstall(_, grant) = state {
                let installed = await installAuthorityGrant(
                    grant,
                    client: client,
                    expectedIdentity: identity
                )
                if !installed {
                    _ = try? await client.coordinator.abandonAuthorityGrant(grant)
                    guard currentDeviceSyncIdentityAfterConflictInstall(
                        from: identity,
                        installationSucceeded: false
                    ) != nil else { return }
                    deviceSyncState = .readOnly
                }
                return
            }
            applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        } catch EpisodeSyncTransportError.unavailable {
            guard deviceSyncContextIsCurrent(identity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            let prior = await client.coordinator.state
            deviceSyncState = authorityVerifiedForActivation &&
                ownsDeviceSyncAuthority(in: prior, client: client, runtime: runtime)
                ? .offlineLocal
                : .readOnly
        } catch {
            guard deviceSyncContextIsCurrent(identity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            deviceSyncState = .blocked
        }
    }

    func forceContinueOnThisMac(expectedIdentity: DeviceSyncEpisodeIdentity) async {
        guard let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity == expectedIdentity,
              deviceSyncState == .readOnly,
              deviceSyncContextIsCurrent(identity),
              let client = deviceSyncClient(for: identity) else { return }

        let initialState = await client.coordinator.state
        if case .conflicted = initialState {
            applyDeviceSyncState(initialState, client: client, expectedIdentity: identity)
            return
        }

        deviceSyncState = .forcing
        do {
            if let pendingGrant = await client.coordinator.authorityGrantAwaitingInstall,
               installedContentDigest(for: pendingGrant, identity: identity) == pendingGrant.snapshot.head?.contentDigest
            {
                let state = try await client.coordinator.confirmAuthorityInstall(
                    pendingGrant,
                    installedRemoteDigest: pendingGrant.snapshot.head?.contentDigest
                )
                guard deviceSyncContextIsCurrent(identity) else {
                    await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                    return
                }
                applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                return
            }

            let grant = try await client.coordinator.prepareForcedContinuation(
                expiresAt: runtime.leaseExpiration()
            )
            try grant.snapshot.head?.validate()
            guard grant.snapshot.head?.key == identity.syncKey || grant.snapshot.head == nil else {
                throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
            }
            guard deviceSyncContextIsCurrent(identity) else {
                _ = try? await client.coordinator.abandonAuthorityGrant(grant)
                return
            }
            let installed = await installAuthorityGrant(
                grant,
                client: client,
                expectedIdentity: identity
            )
            if !installed {
                _ = try? await client.coordinator.abandonAuthorityGrant(grant)
                guard currentDeviceSyncIdentityAfterConflictInstall(
                    from: identity,
                    installationSucceeded: false
                ) != nil else { return }
                deviceSyncState = .readOnly
            }
        } catch {
            guard let currentIdentity = currentDeviceSyncIdentityAfterConflictInstall(
                from: identity,
                installationSucceeded: false
            ) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            let latest = await client.coordinator.state
            applyDeviceSyncState(latest, client: client, expectedIdentity: currentIdentity)
            if case .conflicted = latest {
                return
            }
            deviceSyncState = .readOnly
        }
    }

    func scheduleDeviceSyncForEditedEpisode(
        content: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) {
        guard deviceSyncRuntime != nil,
              resolvedDeviceSyncLookupIdentity == expectedLookup,
              activeDeviceSyncIdentity?.documentSession == expectedLookup.documentSession,
              activeDeviceSyncIdentity?.episodeID == expectedLookup.episodeID,
              activeDeviceSyncIdentity?.editorContentGeneration == expectedLookup.editorContentGeneration,
              deviceSyncState.allowsEditing,
              deviceSyncState != .unconfigured else { return }
        deviceSyncTransferState = .localPending
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.publishDeviceSyncDraft(content: content, expectedLookup: expectedLookup)
        }
    }

    func refreshSelectedEpisodeDeviceSync() async {
        guard deviceSyncState != .syncing, deviceSyncState != .forcing else { return }
        guard let runtime = deviceSyncRuntime,
              var identity = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(identity),
              let client = deviceSyncClient(for: identity) else { return }
        var state = await client.coordinator.state
        if case .restoredUnverified = state {
            guard let recoveredIdentity = await recoverAcceptedMergeIfNeeded(
                state: state,
                client: client,
                expectedIdentity: identity,
                runtime: runtime
            ) else { return }
            identity = recoveredIdentity
            state = await client.coordinator.state
            if case .restoredUnverified = state {
                do {
                    state = try await client.coordinator.synchronize()
                } catch EpisodeSyncTransportError.unavailable {
                    deviceSyncState = .readOnly
                    return
                } catch {
                    deviceSyncState = .blocked
                    return
                }
                guard deviceSyncContextIsCurrent(identity) else { return }
            }
        }
        if case .synchronizing = state {
            // in-flight publish中に同じclientでclaim/inspectしない。
            // publish結果がauthority/fenceを確定し、必要な場合はその経路がrefreshする。
            return
        }
        if case let .conflicted(_, conflict) = state {
            guard await preserveUnjournaledConflictDraftIfNeeded(
                conflict,
                client: client,
                expectedIdentity: identity,
                runtime: runtime
            ) else {
                deviceSyncState = .blocked
                return
            }
            state = await client.coordinator.state
            applyDeviceSyncState(state, client: client, expectedIdentity: identity)
            return
        }
        do {
            if case let .authorityGrantedAwaitingInstall(_, grant) = state {
                let installed = await installAuthorityGrant(
                    grant,
                    client: client,
                    expectedIdentity: identity
                )
                if !installed {
                    _ = try? await client.coordinator.abandonAuthorityGrant(grant)
                    guard currentDeviceSyncIdentityAfterConflictInstall(
                        from: identity,
                        installationSucceeded: false
                    ) != nil else { return }
                    deviceSyncState = .readOnly
                }
                return
            }
            if !ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime) {
                // 相手端末が通常releaseした後はsignal/foreground refreshだけで
                // 通常claimし、破壊的forceを要求しない。
                state = try await client.coordinator.claimEditingAuthority(
                    expiresAt: runtime.leaseExpiration()
                )
                guard deviceSyncContextIsCurrent(identity) else {
                    await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                    return
                }
                if case .conflicted = state {
                    let observation = try await client.coordinator.inspectFence()
                    guard deviceSyncContextIsCurrent(identity) else { return }
                    switch observation {
                    case .authorityValid:
                        if case let .conflicted(_, conflict) = state {
                            guard await preserveUnjournaledConflictDraftIfNeeded(
                                conflict,
                                client: client,
                                expectedIdentity: identity,
                                runtime: runtime
                            ) else {
                                deviceSyncState = .blocked
                                return
                            }
                            state = await client.coordinator.state
                        }
                        applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                    case .authorityLost, .remoteAdvanced:
                        await installFenceObservation(observation, client: client, expectedIdentity: identity)
                    }
                    return
                }
                if case let .authorityGrantedAwaitingInstall(_, grant) = state {
                    let installed = await installAuthorityGrant(
                        grant,
                        client: client,
                        expectedIdentity: identity
                    )
                    if !installed {
                        _ = try? await client.coordinator.abandonAuthorityGrant(grant)
                        guard currentDeviceSyncIdentityAfterConflictInstall(
                            from: identity,
                            installationSucceeded: false
                        ) != nil else { return }
                        deviceSyncState = .readOnly
                    }
                    return
                }
                if ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime) {
                    applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                    return
                }
            }
            let observation = try await client.coordinator.inspectFence()
            guard deviceSyncContextIsCurrent(identity) else { return }
            switch observation {
            case .authorityValid:
                state = await client.coordinator.state
                if case let .conflicted(_, conflict) = state {
                    guard await preserveUnjournaledConflictDraftIfNeeded(
                        conflict,
                        client: client,
                        expectedIdentity: identity,
                        runtime: runtime
                    ) else {
                        deviceSyncState = .blocked
                        return
                    }
                    state = await client.coordinator.state
                }
                applyDeviceSyncState(state, client: client, expectedIdentity: identity)
            case .authorityLost, .remoteAdvanced:
                await installFenceObservation(observation, client: client, expectedIdentity: identity)
            }
        } catch EpisodeSyncTransportError.unavailable {
            guard deviceSyncContextIsCurrent(identity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            state = await client.coordinator.state
            deviceSyncState = ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime)
                ? .offlineLocal
                : .readOnly
        } catch {
            guard deviceSyncContextIsCurrent(identity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return
            }
            deviceSyncState = .readOnly
        }
    }

    /// CloudKit/accountの起動完了signalは、binding解決前にも届く。
    /// 既存clientはexact fenceを再照合し、未解決の話はbindingからやり直す。
    func refreshOrPrepareSelectedEpisodeDeviceSync() async {
        if activeDeviceSyncIdentity != nil {
            await refreshSelectedEpisodeDeviceSync()
        } else if let lookup = currentDeviceSyncLookupIdentity {
            await prepareDeviceSync(for: lookup)
        }
    }

    func resolveDeviceSyncConflict(
        using choice: EpisodeIntegrationChoice,
        expectedConflict: EpisodeConflict
    ) async {
        guard deviceSyncConflict == expectedConflict,
              case .conflict = deviceSyncState,
              let runtime = deviceSyncRuntime,
              var identity = activeDeviceSyncIdentity,
              let client = deviceSyncClient(for: identity) else { return }
        deviceSyncState = .syncing

        let submittedResolution = PendingDeviceSyncConflictResolution(
            key: identity.syncKey,
            conflict: expectedConflict,
            content: choice.resolvedContent(for: expectedConflict)
        )
        do {
            // 利用者が押したexact本文を、force/CAS/fetchの最初のawaitより前に
            // package外markerへdurable化する。ここに失敗したらauthorityを動かさない。
            try await runtime.mergeRecoveryStore.save(
                DeviceSyncMergeRecoveryRecord(
                    localWorkingCopyID: identity.localWorkingCopyID,
                    key: identity.syncKey,
                    conflict: expectedConflict,
                    content: submittedResolution.content
                )
            )
        } catch {
            deviceSyncState = .conflict(expectedConflict)
            return
        }
        guard deviceSyncContextIsCurrent(identity), deviceSyncConflict == expectedConflict else { return }
        pendingDeviceSyncConflictResolution = submittedResolution

        var coordinatorState = await client.coordinator.state
        if !ownsDeviceSyncAuthority(in: coordinatorState, client: client, runtime: runtime) {
            guard let refreshedIdentity = await reacquireDeviceSyncAuthorityForConflict(
                expectedConflict,
                client: client,
                expectedIdentity: identity,
                runtime: runtime
            ) else {
                await rebasePendingDeviceSyncDraftAfterRemoteChange(
                    submittedResolution,
                    client: client,
                    previousIdentity: identity,
                    runtime: runtime
                )
                return
            }
            identity = refreshedIdentity
            coordinatorState = await client.coordinator.state
            guard ownsDeviceSyncAuthority(in: coordinatorState, client: client, runtime: runtime) else { return }
        }

        if let pending = pendingDeviceSyncConflictResolution,
           pending.key == identity.syncKey,
           successfulMergeContext(in: coordinatorState, resolution: pending) != nil
        {
            deviceSyncState = .syncing
            let installed = await installResolvedConflictContent(
                pending.content,
                expectedIdentity: identity
            )
            guard let currentIdentity = currentDeviceSyncIdentityAfterConflictInstall(
                from: identity,
                installationSucceeded: installed
            ) else { return }
            guard installed else {
                deviceSyncConflict = pending.conflict
                deviceSyncState = .conflict(pending.conflict)
                return
            }
            do {
                try await runtime.mergeRecoveryStore.remove(
                    localWorkingCopyID: currentIdentity.localWorkingCopyID,
                    key: currentIdentity.syncKey
                )
            } catch {
                deviceSyncConflict = pending.conflict
                deviceSyncState = .conflict(pending.conflict)
                return
            }
            pendingDeviceSyncConflictResolution = nil
            deviceSyncConflict = nil
            applyDeviceSyncState(coordinatorState, client: client, expectedIdentity: currentIdentity)
            return
        }

        guard case let .conflicted(_, currentConflict) = coordinatorState else {
            // submitted contentがimmutable mergeに入った証明がない限り、
            // markerを消して通常状態へ戻さない。
            if successfulMergeContext(in: coordinatorState, resolution: submittedResolution) == nil {
                deviceSyncState = .blocked
                return
            }
            applyDeviceSyncState(coordinatorState, client: client, expectedIdentity: identity)
            return
        }
        guard currentConflict == expectedConflict else {
            await rebasePendingDeviceSyncDraft(
                submittedResolution,
                to: currentConflict,
                identity: identity,
                runtime: runtime
            )
            return
        }

        let requestedContent = submittedResolution.content
        let resolution: PendingDeviceSyncConflictResolution
        if let pendingDeviceSyncConflictResolution {
            guard pendingDeviceSyncConflictResolution.key == identity.syncKey,
                  pendingDeviceSyncConflictResolution.conflict == currentConflict else {
                await rebasePendingDeviceSyncDraft(
                    submittedResolution,
                    to: currentConflict,
                    identity: identity,
                    runtime: runtime
                )
                return
            }
            if pendingDeviceSyncConflictResolution.content == requestedContent {
                resolution = pendingDeviceSyncConflictResolution
            } else {
                let replacement = PendingDeviceSyncConflictResolution(
                    key: identity.syncKey,
                    conflict: currentConflict,
                    content: requestedContent
                )
                do {
                    try await runtime.mergeRecoveryStore.save(
                        DeviceSyncMergeRecoveryRecord(
                            localWorkingCopyID: identity.localWorkingCopyID,
                            key: identity.syncKey,
                            conflict: currentConflict,
                            content: replacement.content
                        )
                    )
                } catch {
                    deviceSyncConflict = currentConflict
                    deviceSyncState = .conflict(currentConflict)
                    return
                }
                self.pendingDeviceSyncConflictResolution = replacement
                resolution = replacement
            }
        } else {
            resolution = PendingDeviceSyncConflictResolution(
                key: identity.syncKey,
                conflict: currentConflict,
                content: requestedContent
            )
            do {
                try await runtime.mergeRecoveryStore.save(
                    DeviceSyncMergeRecoveryRecord(
                        localWorkingCopyID: identity.localWorkingCopyID,
                        key: identity.syncKey,
                        conflict: currentConflict,
                        content: resolution.content
                    )
                )
            } catch {
                deviceSyncConflict = currentConflict
                deviceSyncState = .conflict(currentConflict)
                return
            }
            pendingDeviceSyncConflictResolution = resolution
        }

        deviceSyncState = .syncing
        do {
            let state: EpisodeSyncState = if coordinatorHasMerge(for: resolution, in: coordinatorState) {
                try await client.coordinator.synchronize()
            } else {
                try await client.coordinator.resolveConflict(
                    using: .manual(content: resolution.content),
                    createdAt: runtime.now()
                )
            }
            guard deviceSyncContextIsCurrent(identity) else { return }
            guard successfulMergeContext(in: state, resolution: resolution) != nil else {
                if case let .conflicted(_, nextConflict) = state {
                    await rebasePendingDeviceSyncDraft(
                        resolution,
                        to: nextConflict,
                        identity: identity,
                        runtime: runtime
                    )
                } else {
                    applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                    deviceSyncConflict = expectedConflict
                }
                return
            }

            let installed = await installResolvedConflictContent(
                resolution.content,
                expectedIdentity: identity
            )
            guard let currentIdentity = currentDeviceSyncIdentityAfterConflictInstall(
                from: identity,
                installationSucceeded: installed
            ) else { return }
            guard installed else {
                deviceSyncConflict = expectedConflict
                deviceSyncState = .conflict(expectedConflict)
                return
            }
            do {
                try await runtime.mergeRecoveryStore.remove(
                    localWorkingCopyID: currentIdentity.localWorkingCopyID,
                    key: currentIdentity.syncKey
                )
            } catch {
                deviceSyncConflict = resolution.conflict
                deviceSyncState = .conflict(resolution.conflict)
                return
            }
            pendingDeviceSyncConflictResolution = nil
            deviceSyncConflict = nil
            applyDeviceSyncState(state, client: client, expectedIdentity: currentIdentity)
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return }
            deviceSyncConflict = expectedConflict
            deviceSyncState = .conflict(expectedConflict)
        }
    }

    private func rebasePendingDeviceSyncDraftAfterRemoteChange(
        _ resolution: PendingDeviceSyncConflictResolution,
        client: DeviceSyncClient,
        previousIdentity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard let currentIdentity = activeDeviceSyncIdentity,
              currentIdentity.localWorkingCopyID == previousIdentity.localWorkingCopyID,
              currentIdentity.syncKey == previousIdentity.syncKey,
              deviceSyncContextIsCurrent(currentIdentity) else {
            deviceSyncState = .blocked
            return
        }
        let state = await client.coordinator.state
        guard case let .conflicted(_, conflict) = state else {
            deviceSyncState = .blocked
            return
        }
        await rebasePendingDeviceSyncDraft(
            resolution,
            to: conflict,
            identity: currentIdentity,
            runtime: runtime
        )
    }

    private func rebasePendingDeviceSyncDraft(
        _ resolution: PendingDeviceSyncConflictResolution,
        to conflict: EpisodeConflict,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard resolution.key == identity.syncKey,
              conflict.local.revisionID == resolution.conflict.local.revisionID else {
            // local parentまで変わった場合は、旧markerを消さず停止する。
            deviceSyncState = .blocked
            return
        }
        let rebased = PendingDeviceSyncConflictResolution(
            key: identity.syncKey,
            conflict: conflict,
            content: resolution.content
        )
        do {
            try await runtime.mergeRecoveryStore.save(
                DeviceSyncMergeRecoveryRecord(
                    localWorkingCopyID: identity.localWorkingCopyID,
                    key: identity.syncKey,
                    conflict: conflict,
                    content: rebased.content
                )
            )
        } catch {
            deviceSyncState = .blocked
            return
        }
        pendingDeviceSyncConflictResolution = rebased
        deviceSyncConflict = conflict
        deviceSyncState = .conflict(conflict)
    }

    /// fence後のeditorはremote本文なので、競合解決用のauthority再取得では新しいlocal forkを作らない。
    /// CAS中にremoteが進んだ場合も、既存のlocal parentを保持したままexact remoteだけを差し替える。
    private func reacquireDeviceSyncAuthorityForConflict(
        _ expectedConflict: EpisodeConflict,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> DeviceSyncEpisodeIdentity? {
        deviceSyncState = .forcing
        do {
            let grant = if let pending = await client.coordinator.authorityGrantAwaitingInstall {
                pending
            } else {
                try await client.coordinator.prepareConflictResolutionAuthority(
                    expectedConflict: expectedConflict,
                    expiresAt: runtime.leaseExpiration()
                )
            }
            guard let remote = grant.snapshot.head else {
                throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
            }
            try remote.validate()
            guard remote.key == expectedIdentity.syncKey,
                  deviceSyncContextIsCurrent(expectedIdentity) else {
                throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
            }

            let installedDigest: SyncContentDigest
            let identityAfterInstall: DeviceSyncEpisodeIdentity
            if installedContentDigest(for: grant, identity: expectedIdentity) == remote.contentDigest {
                installedDigest = remote.contentDigest
                identityAfterInstall = expectedIdentity
            } else {
                guard case let .installed(digest) = await installConflictRemoteGrant(
                    grant,
                    expectedIdentity: expectedIdentity
                ), digest == remote.contentDigest,
                let currentIdentity = currentDeviceSyncIdentityAfterSingleInstall(from: expectedIdentity) else {
                    await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                    return nil
                }
                installedDigest = remote.contentDigest
                identityAfterInstall = currentIdentity
            }

            let state = try await client.coordinator.confirmAuthorityInstall(
                grant,
                installedRemoteDigest: installedDigest
            )
            guard deviceSyncContextIsCurrent(identityAfterInstall) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return nil
            }
            applyDeviceSyncState(state, client: client, expectedIdentity: identityAfterInstall)
            return ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime)
                ? identityAfterInstall
                : nil
        } catch {
            await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
            guard deviceSyncContextIsCurrent(expectedIdentity) else { return nil }
            let state = await client.coordinator.state
            applyDeviceSyncState(state, client: client, expectedIdentity: expectedIdentity)
            if deviceSyncConflict == nil {
                deviceSyncConflict = expectedConflict
                deviceSyncState = .conflict(expectedConflict)
            }
            return nil
        }
    }

    private func installConflictRemoteGrant(
        _ grant: EpisodeAuthorityGrant,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async -> DeviceSyncInstallResult {
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  beginDocumentTransition() else { return .failed }
            defer { endDocumentTransition() }
            guard let committedContent = capturedCommittedContent(for: expectedIdentity) else { return .failed }
            if document.episode(expectedIdentity.episodeID)?.episode.content != committedContent {
                installDeviceSyncEpisodeContent(
                    committedContent,
                    chapterID: expectedIdentity.chapterID,
                    episodeID: expectedIdentity.episodeID,
                    advancesEditorGeneration: false
                )
            } else {
                saveCoordinator.markDirty()
            }

            do {
                let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    guard deviceSyncContextIsCurrent(expectedIdentity),
                          let remote = grant.snapshot.head else { return SyncContentDigest?.none }
                    try remote.validate()
                    guard remote.key == expectedIdentity.syncKey else {
                        throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
                    }
                    installDeviceSyncEpisodeContent(
                        remote.content,
                        chapterID: expectedIdentity.chapterID,
                        episodeID: expectedIdentity.episodeID,
                        advancesEditorGeneration: true
                    )
                    updateDeviceSyncIdentityAfterRemoteInstall(expectedIdentity)
                    return remote.contentDigest
                }
                switch result {
                case .saveFailedBeforeOperation:
                    return .failed
                case let .completed(digest, savedAfterOperation):
                    return savedAfterOperation ? .installed(digest) : .failed
                }
            } catch {
                return .failed
            }
        }
    }

    private func publishDeviceSyncDraft(
        content: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) async {
        guard deviceSyncState == .writer || deviceSyncState == .offlineLocal,
              let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity.documentSession == expectedLookup.documentSession,
              identity.episodeID == expectedLookup.episodeID,
              identity.editorContentGeneration == expectedLookup.editorContentGeneration,
              let client = deviceSyncClient(for: identity) else { return }
        deviceSyncTransferState = .uploading
        let recordedState = await documentOperationGate.perform { [weak self] () -> EpisodeSyncState? in
            guard let self,
                  deviceSyncContextIsCurrent(identity),
                  document.episode(identity.episodeID)?.episode.content == content,
                  await saveCoordinator.saveNow() else { return nil }
            do {
                return try await client.coordinator.recordLocalContent(content, createdAt: runtime.now())
            } catch {
                return nil
            }
        }
        guard deviceSyncContextIsCurrent(identity) else { return }
        guard let recordedState else {
            let prior = await client.coordinator.state
            deviceSyncState = ownsDeviceSyncAuthority(in: prior, client: client, runtime: runtime)
                ? .offlineLocal
                : .readOnly
            return
        }
        guard !Task.isCancelled else {
            applyDeviceSyncState(recordedState, client: client, expectedIdentity: identity)
            return
        }
        let resultingState: EpisodeSyncState
        do {
            resultingState = try await synchronizeRecordedDeviceSyncDraft(
                client: client,
                expectedIdentity: identity
            )
        } catch {
            let prior = await client.coordinator.state
            deviceSyncState = ownsDeviceSyncAuthority(in: prior, client: client, runtime: runtime)
                ? .offlineLocal
                : .readOnly
            return
        }
        guard deviceSyncContextIsCurrent(identity) else { return }
        var reconciledState = resultingState
        if case let .conflicted(_, conflict) = reconciledState {
            guard await preserveUnjournaledConflictDraftIfNeeded(
                conflict,
                client: client,
                expectedIdentity: identity,
                runtime: runtime,
                updatesJournalLocal: true
            ) else {
                deviceSyncState = .blocked
                return
            }
            reconciledState = await client.coordinator.state
        }
        applyDeviceSyncState(reconciledState, client: client, expectedIdentity: identity)
        if case .authorityLost = reconciledState {
            await refreshSelectedEpisodeDeviceSync()
        } else if case .remoteUpdateAvailable = reconciledState {
            await refreshSelectedEpisodeDeviceSync()
        }
    }

    private func synchronizeRecordedDeviceSyncDraft(
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async throws -> EpisodeSyncState {
        let first = try await client.coordinator.synchronize()
        guard let runtime = deviceSyncRuntime,
              !Task.isCancelled,
              deviceSyncContextIsCurrent(expectedIdentity),
              ownsDeviceSyncAuthority(in: first, client: client, runtime: runtime),
              case .localChanges = first else { return first }

        // 送信中に記録された本文は、進行中のsealed batchとは別のtailになる。
        // 旧batchのack後に残るtailをもう一度だけsealして送る。
        return try await client.coordinator.synchronize()
    }

    private func installAuthorityGrant(
        _ grant: EpisodeAuthorityGrant,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime else { return false }
        deviceSyncState = .syncing
        let installResult = await documentOperationGate.perform { [weak self] in
            guard let self else { return DeviceSyncInstallResult.failed }
            return await installAuthorityGrantSerially(
                grant,
                client: client,
                expectedIdentity: expectedIdentity
            )
        }
        let digest: SyncContentDigest?
        let currentIdentity: DeviceSyncEpisodeIdentity
        switch installResult {
        case .failed:
            if !deviceSyncContextIsCurrent(expectedIdentity) {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
            }
            return false
        case let .alreadyInstalled(installedDigest):
            guard deviceSyncContextIsCurrent(expectedIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            digest = installedDigest
            currentIdentity = expectedIdentity
        case let .installed(installedDigest):
            guard let identityAfterInstall = currentDeviceSyncIdentityAfterSingleInstall(from: expectedIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            digest = installedDigest
            currentIdentity = identityAfterInstall
        }
        do {
            let state = try await client.coordinator.confirmAuthorityInstall(
                grant,
                installedRemoteDigest: digest
            )
            guard deviceSyncContextIsCurrent(currentIdentity) else {
                await relinquishStaleDeviceSyncAuthority(
                    client: client,
                    runtime: runtime
                )
                return false
            }
            applyDeviceSyncState(state, client: client, expectedIdentity: currentIdentity)
            return true
        } catch {
            guard deviceSyncContextIsCurrent(currentIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            let latest = await client.coordinator.state
            applyDeviceSyncState(latest, client: client, expectedIdentity: currentIdentity)
            if case .conflicted = latest {
                return true
            }
            deviceSyncState = .readOnly
            return true
        }
    }

    private func installAuthorityGrantSerially(
        _ grant: EpisodeAuthorityGrant,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async -> DeviceSyncInstallResult {
        guard deviceSyncContextIsCurrent(expectedIdentity), beginDocumentTransition() else { return .failed }
        defer { endDocumentTransition() }
        guard let localContent = capturedCommittedContent(for: expectedIdentity) else { return .failed }
        if document.episode(expectedIdentity.episodeID)?.episode.content != localContent {
            installDeviceSyncEpisodeContent(
                localContent,
                chapterID: expectedIdentity.chapterID,
                episodeID: expectedIdentity.episodeID,
                advancesEditorGeneration: false
            )
        } else {
            saveCoordinator.markDirty()
        }

        do {
            let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard deviceSyncContextIsCurrent(expectedIdentity) else {
                    return DeviceSyncInstallResult.failed
                }
                let remote = grant.snapshot.head
                if let remote {
                    try remote.validate()
                    guard remote.key == expectedIdentity.syncKey else {
                        throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
                    }
                }

                // confirmの応答だけ失敗した再試行では、package/editorは既にexact remote本文である。
                // ここで再びpreserveすると、先に保存したlocal forkをremote本文でcoalesceして失う。
                if remote == nil || SyncContentDigest(content: localContent) == remote?.contentDigest {
                    return .alreadyInstalled(remote?.contentDigest)
                }

                _ = try await client.coordinator.preserveLocalFork(
                    content: localContent,
                    createdAt: deviceSyncRuntime?.now() ?? Date(),
                    for: grant
                )
                guard deviceSyncContextIsCurrent(expectedIdentity) else {
                    return DeviceSyncInstallResult.failed
                }
                if let remote {
                    installDeviceSyncEpisodeContent(
                        remote.content,
                        chapterID: expectedIdentity.chapterID,
                        episodeID: expectedIdentity.episodeID,
                        advancesEditorGeneration: true
                    )
                } else {
                    installDeviceSyncEpisodeContent(
                        localContent,
                        chapterID: expectedIdentity.chapterID,
                        episodeID: expectedIdentity.episodeID,
                        advancesEditorGeneration: true
                    )
                }
                updateDeviceSyncIdentityAfterRemoteInstall(expectedIdentity)
                return .installed(remote?.contentDigest)
            }
            switch result {
            case .saveFailedBeforeOperation:
                return .failed
            case let .completed(installResult, savedAfterOperation):
                return savedAfterOperation ? installResult : .failed
            }
        } catch {
            return .failed
        }
    }

    private func installFenceObservation(
        _ observation: EpisodeFenceObservation,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async {
        guard deviceSyncContextIsCurrent(expectedIdentity), let snapshot = fencedSnapshot(from: observation) else { return }
        deviceSyncState = .syncing
        let installResult = await documentOperationGate.perform { [weak self] in
            guard let self else { return DeviceSyncInstallResult.failed }
            guard deviceSyncContextIsCurrent(expectedIdentity), beginDocumentTransition() else { return .failed }
            defer { endDocumentTransition() }
            guard let localContent = capturedCommittedContent(for: expectedIdentity) else { return .failed }
            if document.episode(expectedIdentity.episodeID)?.episode.content != localContent {
                installDeviceSyncEpisodeContent(
                    localContent,
                    chapterID: expectedIdentity.chapterID,
                    episodeID: expectedIdentity.episodeID,
                    advancesEditorGeneration: false
                )
            } else {
                saveCoordinator.markDirty()
            }
            do {
                let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    _ = try await client.coordinator.preserveLocalFork(
                        content: localContent,
                        createdAt: deviceSyncRuntime?.now() ?? Date(),
                        for: observation
                    )
                    guard deviceSyncContextIsCurrent(expectedIdentity) else { return SyncContentDigest?.none }
                    if let remote = snapshot.head {
                        try remote.validate()
                        guard remote.key == expectedIdentity.syncKey else {
                            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
                        }
                        installDeviceSyncEpisodeContent(
                            remote.content,
                            chapterID: expectedIdentity.chapterID,
                            episodeID: expectedIdentity.episodeID,
                            advancesEditorGeneration: true
                        )
                    } else {
                        installDeviceSyncEpisodeContent(
                            localContent,
                            chapterID: expectedIdentity.chapterID,
                            episodeID: expectedIdentity.episodeID,
                            advancesEditorGeneration: true
                        )
                    }
                    updateDeviceSyncIdentityAfterRemoteInstall(expectedIdentity)
                    return snapshot.head?.contentDigest
                }
                switch result {
                case .saveFailedBeforeOperation:
                    return .failed
                case let .completed(digest, savedAfterOperation):
                    return savedAfterOperation ? .installed(digest) : .failed
                }
            } catch {
                return .failed
            }
        }
        guard case let .installed(digest) = installResult,
              let currentIdentity = currentDeviceSyncIdentityAfterSingleInstall(from: expectedIdentity) else
        {
            if deviceSyncContextIsCurrent(expectedIdentity) {
                deviceSyncState = .readOnly
            }
            return
        }
        do {
            let state = try await client.coordinator.confirmObservedRemoteInstall(
                observation,
                installedRemoteDigest: digest
            )
            applyDeviceSyncState(state, client: client, expectedIdentity: currentIdentity)
        } catch {
            guard deviceSyncContextIsCurrent(currentIdentity) else { return }
            let current = await client.coordinator.state
            applyDeviceSyncState(current, client: client, expectedIdentity: currentIdentity)
            if case .conflicted = current { return }
            deviceSyncState = .readOnly
        }
    }

    private func installResolvedConflictContent(
        _ content: String,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async -> Bool {
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            saveCoordinator.markDirty()
            let result = await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard deviceSyncContextIsCurrent(expectedIdentity) else { return false }
                installDeviceSyncEpisodeContent(
                    content,
                    chapterID: expectedIdentity.chapterID,
                    episodeID: expectedIdentity.episodeID,
                    advancesEditorGeneration: true
                )
                updateDeviceSyncIdentityAfterRemoteInstall(expectedIdentity)
                return true
            }
            switch result {
            case .saveFailedBeforeOperation:
                return false
            case let .completed(didInstall, savedAfterOperation):
                return didInstall && savedAfterOperation
            }
        }
    }

    private func capturedCommittedContent(for identity: DeviceSyncEpisodeIdentity) -> String? {
        switch captureCommittedTextForDeviceSync() {
        case let .captured(content):
            content
        case .notActive:
            document.episode(identity.episodeID)?.episode.content
        case .compositionInProgress:
            nil
        }
    }

    private func installedContentDigest(
        for grant: EpisodeAuthorityGrant,
        identity: DeviceSyncEpisodeIdentity
    ) -> SyncContentDigest? {
        guard let remote = grant.snapshot.head,
              let content = document.episode(identity.episodeID)?.episode.content else { return nil }
        return SyncContentDigest(content: content) == remote.contentDigest ? remote.contentDigest : nil
    }

    private func startDeviceSyncSignalObservationIfNeeded() {
        guard deviceSyncSignalTask == nil,
              let signals = deviceSyncRuntime?.remoteChangeSignals else { return }
        deviceSyncSignalTask = Task { @MainActor [weak self] in
            for await _ in signals {
                guard !Task.isCancelled else { return }
                await self?.refreshOrPrepareSelectedEpisodeDeviceSync()
            }
        }
    }

    private func updateDeviceSyncIdentityAfterRemoteInstall(_ previous: DeviceSyncEpisodeIdentity) {
        let updated = DeviceSyncEpisodeIdentity(
            documentSession: documentSessionToken,
            chapterID: previous.chapterID,
            episodeID: previous.episodeID,
            editorContentGeneration: editorContentGeneration,
            structureDigest: previous.structureDigest,
            localWorkingCopyID: previous.localWorkingCopyID,
            syncKey: previous.syncKey
        )
        activeDeviceSyncIdentity = updated
        resolvedDeviceSyncLookupIdentity = DeviceSyncLookupIdentity(
            documentSession: updated.documentSession,
            chapterID: updated.chapterID,
            episodeID: updated.episodeID,
            editorContentGeneration: updated.editorContentGeneration,
            structureDigest: updated.structureDigest
        )
    }

    func applyDeviceSyncState(
        _ state: EpisodeSyncState,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) {
        guard deviceSyncContextIsCurrent(expectedIdentity),
              let runtime = deviceSyncRuntime else { return }
        switch state {
        case let .upToDate(context):
            deviceSyncState = ownsDeviceSyncAuthority(context: context, client: client, runtime: runtime)
                ? .writer
                : .readOnly
            if deviceSyncState == .writer {
                deviceSyncConflict = nil
                deviceSyncTransferState = .upToDate
            }
        case let .localChanges(context):
            deviceSyncState = ownsDeviceSyncAuthority(context: context, client: client, runtime: runtime)
                ? .writer
                : .readOnly
            if deviceSyncState == .writer {
                deviceSyncTransferState = .localPending
            }
        case .offlineFork:
            deviceSyncState = .offlineLocal
            deviceSyncTransferState = .localPending
        case let .conflicted(_, conflict):
            deviceSyncConflict = conflict
            deviceSyncState = .conflict(conflict)
        case .readOnly, .authorityLost, .restoredUnverified:
            deviceSyncState = .readOnly
            deviceSyncTransferState = .notApplicable
        case .synchronizing, .remoteUpdateAvailable, .authorityGrantedAwaitingInstall:
            deviceSyncState = .syncing
        case .unlinked:
            deviceSyncState = .blocked
        }
    }

    func ownsDeviceSyncAuthority(
        in state: EpisodeSyncState,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) -> Bool {
        let context: EpisodeSyncContext? = switch state {
        case let .upToDate(value), let .localChanges(value), let .offlineFork(value), let .conflicted(value, _):
            value
        default:
            nil
        }
        guard let context else { return false }
        return ownsDeviceSyncAuthority(context: context, client: client, runtime: runtime)
    }

    func ownsDeviceSyncAuthority(
        context: EpisodeSyncContext,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) -> Bool {
        context.lease?.authority.holderReplicaID == runtime.replicaID &&
            context.lease?.authority.holderSessionID == client.sessionID
    }

    private func relinquishStaleDeviceSyncAuthority(
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) async {
        if let grant = await client.coordinator.authorityGrantAwaitingInstall {
            _ = try? await client.coordinator.abandonAuthorityGrant(grant)
            return
        }
        let state = await client.coordinator.state
        guard ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime) else { return }
        _ = try? await client.coordinator.releaseEditingAuthority()
    }

    func deviceSyncClient(for identity: DeviceSyncEpisodeIdentity) -> DeviceSyncClient? {
        deviceSyncClients[
            DeviceSyncClientKey(
                localWorkingCopyID: identity.localWorkingCopyID,
                syncKey: identity.syncKey
            )
        ]
    }

    func deviceSyncContextIsCurrent(_ identity: DeviceSyncEpisodeIdentity) -> Bool {
        activeDeviceSyncIdentity == identity &&
            currentDeviceSyncLookupIdentity == DeviceSyncLookupIdentity(
                documentSession: identity.documentSession,
                chapterID: identity.chapterID,
                episodeID: identity.episodeID,
                editorContentGeneration: identity.editorContentGeneration,
                structureDigest: identity.structureDigest
            )
    }

    private func currentDeviceSyncIdentityAfterSingleInstall(
        from previous: DeviceSyncEpisodeIdentity
    ) -> DeviceSyncEpisodeIdentity? {
        guard let current = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(current),
              current.documentSession == previous.documentSession,
              current.chapterID == previous.chapterID,
              current.episodeID == previous.episodeID,
              current.localWorkingCopyID == previous.localWorkingCopyID,
              current.syncKey == previous.syncKey,
              current.editorContentGeneration == previous.editorContentGeneration &+ 1 else { return nil }
        return current
    }

    private func currentDeviceSyncIdentityAfterConflictInstall(
        from previous: DeviceSyncEpisodeIdentity,
        installationSucceeded: Bool
    ) -> DeviceSyncEpisodeIdentity? {
        if installationSucceeded {
            return currentDeviceSyncIdentityAfterSingleInstall(from: previous)
        }
        guard let current = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(current),
              current == previous || currentDeviceSyncIdentityAfterSingleInstall(from: previous) != nil else {
            return nil
        }
        return current
    }

    private func preserveUnjournaledConflictDraftIfNeeded(
        _ conflict: EpisodeConflict,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime,
        updatesJournalLocal: Bool = false
    ) async -> Bool {
        if pendingDeviceSyncConflictResolution?.key == expectedIdentity.syncKey {
            // 既存markerは利用者が選んだ唯一の統合案である。以前installしたremote本文を
            // 新しいlocal入力と誤認して上書きしない。
            return true
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            guard let committed = capturedCommittedContent(for: expectedIdentity) else { return false }
            let digest = SyncContentDigest(content: committed)
            guard digest != conflict.local.contentDigest,
                  digest != conflict.remote.contentDigest else { return true }
            if document.episode(expectedIdentity.episodeID)?.episode.content != committed {
                installDeviceSyncEpisodeContent(
                    committed,
                    chapterID: expectedIdentity.chapterID,
                    episodeID: expectedIdentity.episodeID,
                    advancesEditorGeneration: false
                )
            } else {
                saveCoordinator.markDirty()
            }
            guard await saveCoordinator.saveNow() else { return false }
            let reconciledConflict: EpisodeConflict
            if updatesJournalLocal {
                let reconciledState: EpisodeSyncState
                do {
                    reconciledState = try await client.coordinator.preserveConflictLocalContent(
                        committed,
                        expectedConflict: conflict,
                        createdAt: runtime.now()
                    )
                } catch {
                    return false
                }
                guard case let .conflicted(_, updatedConflict) = reconciledState else { return false }
                reconciledConflict = updatedConflict
            } else {
                // fresh restoreや既存conflict refreshでは、第三のpackage本文のprovenanceを
                // writer中の追記と証明できない。journal localは変えずmarkerだけに残す。
                reconciledConflict = conflict
            }
            let resolution = PendingDeviceSyncConflictResolution(
                key: expectedIdentity.syncKey,
                conflict: reconciledConflict,
                content: committed
            )
            do {
                try await runtime.mergeRecoveryStore.save(
                    DeviceSyncMergeRecoveryRecord(
                        localWorkingCopyID: expectedIdentity.localWorkingCopyID,
                        key: expectedIdentity.syncKey,
                        conflict: reconciledConflict,
                        content: committed
                    )
                )
            } catch {
                return false
            }
            pendingDeviceSyncConflictResolution = resolution
            return true
        }
    }

    private func recoverAcceptedMergeIfNeeded(
        state initialState: EpisodeSyncState,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> DeviceSyncEpisodeIdentity? {
        let record: DeviceSyncMergeRecoveryRecord
        do {
            guard let loaded = try await runtime.mergeRecoveryStore.load(
                localWorkingCopyID: expectedIdentity.localWorkingCopyID,
                key: expectedIdentity.syncKey
            ) else { return expectedIdentity }
            record = loaded
        } catch {
            deviceSyncState = .blocked
            return nil
        }
        var verifiedState = initialState
        var observation: EpisodeFenceObservation?
        do {
            if case .restoredUnverified = verifiedState {
                verifiedState = try await client.coordinator.synchronize()
            }
            if case let .conflicted(_, conflict) = verifiedState,
               mergeRecoveryRecord(record, matches: conflict)
            {
                pendingDeviceSyncConflictResolution = PendingDeviceSyncConflictResolution(
                    key: record.key,
                    conflict: conflict,
                    content: record.content
                )
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return nil
            }
            if case let .conflicted(_, conflict) = verifiedState,
               mergeRecoveryRecord(record, matches: conflict.local)
            {
                // 選択済みmergeはjournalにdurable化済みだが、その後remoteが
                // 進んだ。古いmarkerを消し、merge/remoteの新しい競合をそのまま出す。
                try await runtime.mergeRecoveryStore.remove(
                    localWorkingCopyID: record.localWorkingCopyID,
                    key: record.key
                )
                pendingDeviceSyncConflictResolution = nil
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return nil
            }
            if case let .conflicted(_, conflict) = verifiedState,
               conflict.local.revisionID == record.localParentRevisionID
            {
                // marker保存後・domain merge作成前に終了し、remoteだけが
                // 進んだ場合。以前の選択本文を新しいexact pairの
                // 確認用draftへatomicに張り替え、自動publishはしない。
                let rebasedRecord = DeviceSyncMergeRecoveryRecord(
                    localWorkingCopyID: record.localWorkingCopyID,
                    key: record.key,
                    conflict: conflict,
                    content: record.content
                )
                try await runtime.mergeRecoveryStore.save(rebasedRecord)
                pendingDeviceSyncConflictResolution = PendingDeviceSyncConflictResolution(
                    key: record.key,
                    conflict: conflict,
                    content: record.content
                )
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return nil
            }
            if !mergeRecoveryRecord(record, wasAcceptedIn: verifiedState) {
                let inspected = try await client.coordinator.inspectFence()
                guard let remote = inspected.remoteSnapshot?.head,
                      mergeRecoveryRecord(record, matches: remote) else {
                    deviceSyncState = .blocked
                    return nil
                }
                observation = inspected
            }
        } catch {
            deviceSyncState = .blocked
            return nil
        }
        let installed = await installResolvedConflictContent(
            record.content,
            expectedIdentity: expectedIdentity
        )
        guard installed,
              let currentIdentity = currentDeviceSyncIdentityAfterSingleInstall(from: expectedIdentity) else {
            deviceSyncState = .blocked
            return nil
        }
        if let observation {
            do {
                verifiedState = try await client.coordinator.confirmObservedRemoteInstall(
                    observation,
                    installedRemoteDigest: record.contentDigest
                )
            } catch {
                deviceSyncState = .blocked
                return nil
            }
        }
        do {
            try await runtime.mergeRecoveryStore.remove(
                localWorkingCopyID: record.localWorkingCopyID,
                key: record.key
            )
        } catch {
            deviceSyncState = .blocked
            return nil
        }
        pendingDeviceSyncConflictResolution = nil
        deviceSyncConflict = nil
        applyDeviceSyncState(verifiedState, client: client, expectedIdentity: currentIdentity)
        return currentIdentity
    }

    private func mergeRecoveryRecord(
        _ record: DeviceSyncMergeRecoveryRecord,
        matches conflict: EpisodeConflict
    ) -> Bool {
        Set([conflict.local.revisionID, conflict.remote.revisionID]) == record.parentRevisionIDs
    }

    private func mergeRecoveryRecord(
        _ record: DeviceSyncMergeRecoveryRecord,
        matches revision: EpisodeRevision
    ) -> Bool {
        Set(revision.parentRevisionIDs) == record.parentRevisionIDs &&
            revision.contentDigest == record.contentDigest
    }

    private func mergeRecoveryRecord(
        _ record: DeviceSyncMergeRecoveryRecord,
        wasAcceptedIn state: EpisodeSyncState
    ) -> Bool {
        guard let context = deviceSyncContext(from: state),
              context.pendingRevisionCount == 0 else { return false }
        return mergeRecoveryRecord(record, matches: context.localHead)
    }

    private func deviceSyncContext(from state: EpisodeSyncState) -> EpisodeSyncContext? {
        switch state {
        case let .restoredUnverified(context),
             let .upToDate(context),
             let .localChanges(context),
             let .offlineFork(context),
             let .synchronizing(context),
             let .authorityGrantedAwaitingInstall(context, _),
             let .readOnly(context, _),
             let .authorityLost(context, _),
             let .remoteUpdateAvailable(context, _),
             let .conflicted(context, _):
            context
        case .unlinked:
            nil
        }
    }

    private func discardPendingMergeRecovery() async -> Bool {
        guard let pending = pendingDeviceSyncConflictResolution,
              let identity = activeDeviceSyncIdentity,
              let runtime = deviceSyncRuntime else { return true }
        do {
            try await runtime.mergeRecoveryStore.remove(
                localWorkingCopyID: identity.localWorkingCopyID,
                key: pending.key
            )
            return true
        } catch {
            return false
        }
    }


    private func coordinatorHasMerge(
        for resolution: PendingDeviceSyncConflictResolution,
        in state: EpisodeSyncState
    ) -> Bool {
        let context: EpisodeSyncContext? = switch state {
        case let .upToDate(value), let .localChanges(value), let .offlineFork(value), let .synchronizing(value):
            value
        default:
            nil
        }
        guard let context else { return false }
        let expectedParents = Set([
            resolution.conflict.local.revisionID,
            resolution.conflict.remote.revisionID
        ])
        return Set(context.localHead.parentRevisionIDs) == expectedParents &&
            context.localHead.contentDigest == SyncContentDigest(content: resolution.content)
    }

    private func successfulMergeContext(
        in state: EpisodeSyncState,
        resolution: PendingDeviceSyncConflictResolution
    ) -> EpisodeSyncContext? {
        guard case let .upToDate(context) = state,
              context.pendingRevisionCount == 0 else { return nil }
        let expectedParents = Set([
            resolution.conflict.local.revisionID,
            resolution.conflict.remote.revisionID
        ])
        guard Set(context.localHead.parentRevisionIDs) == expectedParents,
              context.localHead.contentDigest == SyncContentDigest(content: resolution.content) else { return nil }
        return context
    }

    private func fencedSnapshot(from observation: EpisodeFenceObservation) -> EpisodeRemoteSnapshot? {
        switch observation {
        case .authorityValid:
            nil
        case let .authorityLost(snapshot), let .remoteAdvanced(snapshot):
            snapshot
        }
    }
}

private enum DeviceSyncInstallResult: Sendable {
    case failed
    case alreadyInstalled(SyncContentDigest?)
    case installed(SyncContentDigest?)
}
