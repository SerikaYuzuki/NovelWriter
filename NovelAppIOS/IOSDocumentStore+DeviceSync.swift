import EditorKit
import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    var currentDeviceSyncLookupIdentity: IOSDeviceSyncLookupIdentity? {
        guard startupState == .ready,
              let editingToken = currentEpisodeEditingToken,
              let structureDigest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return nil }
        return IOSDeviceSyncLookupIdentity(
            editingToken: editingToken,
            structureDigest: structureDigest
        )
    }

    func deviceSyncAllowsEditing(for lookup: IOSDeviceSyncLookupIdentity) -> Bool {
        guard !deviceSyncStartupFailedSafely, startupState == .ready else { return false }
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
        if pendingDeviceSyncNewWork?.session != currentDocumentSessionToken {
            pendingDeviceSyncNewWork = nil
        }
    }

    func prepareDeviceSync(for expectedLookup: IOSDeviceSyncLookupIdentity) async {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        startDeviceSyncSignalObservationIfNeeded()
        if resolvedDeviceSyncLookupIdentity == expectedLookup,
           activeDeviceSyncIdentity?.editingToken == expectedLookup.editingToken || deviceSyncRuntime == nil
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

        let resolution: IOSDeviceSyncBindingResolution?
        do {
            resolution = try await runtime.binding(
                expectedLookup.editingToken.documentSession.workingCopyID,
                document.id,
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
        guard resolution.allowedEpisodeIDs.contains(expectedLookup.editingToken.episodeID) else {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            activeDeviceSyncIdentity = nil
            deviceSyncState = .episodeNotIncluded
            return
        }

        let syncKey = EpisodeSyncKey(
            workID: binding.workID,
            episodeID: expectedLookup.editingToken.episodeID
        )
        let clientKey = IOSDeviceSyncClientKey(
            localWorkingCopyID: binding.localWorkingCopyID,
            syncKey: syncKey
        )
        let client: IOSDeviceSyncClient
        let isNewClient: Bool
        if let existing = deviceSyncClients[clientKey] {
            client = existing
            isNewClient = false
        } else {
            let sessionID = SyncEditSessionID()
            client = IOSDeviceSyncClient(
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

        var identity = IOSDeviceSyncEpisodeIdentity(
            editingToken: expectedLookup.editingToken,
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
                let localContent = document.episode(identity.editingToken.episodeID)?.episode.content ?? ""
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
                let packageContent = document.episode(identity.editingToken.episodeID)?.episode.content ?? ""
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
                    expectedIdentity: identity,
                    progressState: .syncing
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

    func forceContinueOnThisIPhone(expectedIdentity: IOSDeviceSyncEpisodeIdentity) async {
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

            // remote fetch + epoch CASをeditor/package lockより先に完了させる。
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
                expectedIdentity: identity,
                progressState: .forcing
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
        expectedEditingToken: IOSEpisodeEditingToken
    ) {
        guard deviceSyncRuntime != nil,
              let expectedLookup = currentDeviceSyncLookupIdentity,
              expectedLookup.editingToken == expectedEditingToken,
              activeDeviceSyncIdentity?.editingToken == expectedEditingToken,
              resolvedDeviceSyncLookupIdentity == expectedLookup,
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
            await self?.publishDeviceSyncDraft(content: content, expectedEditingToken: expectedEditingToken)
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
                    expectedIdentity: identity,
                    progressState: .syncing
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
                        expectedIdentity: identity,
                        progressState: .syncing
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

        let submittedResolution = IOSPendingDeviceSyncConflictResolution(
            key: identity.syncKey,
            conflict: expectedConflict,
            content: choice.resolvedContent(for: expectedConflict)
        )
        do {
            try await runtime.mergeRecoveryStore.save(
                IOSDeviceSyncMergeRecoveryRecord(
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
        let resolution: IOSPendingDeviceSyncConflictResolution
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
                let replacement = IOSPendingDeviceSyncConflictResolution(
                    key: identity.syncKey,
                    conflict: currentConflict,
                    content: requestedContent
                )
                do {
                    try await runtime.mergeRecoveryStore.save(
                        IOSDeviceSyncMergeRecoveryRecord(
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
            resolution = IOSPendingDeviceSyncConflictResolution(
                key: identity.syncKey,
                conflict: currentConflict,
                content: requestedContent
            )
            do {
                try await runtime.mergeRecoveryStore.save(
                    IOSDeviceSyncMergeRecoveryRecord(
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
        _ resolution: IOSPendingDeviceSyncConflictResolution,
        client: IOSDeviceSyncClient,
        previousIdentity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
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
        _ resolution: IOSPendingDeviceSyncConflictResolution,
        to conflict: EpisodeConflict,
        identity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async {
        guard resolution.key == identity.syncKey,
              conflict.local.revisionID == resolution.conflict.local.revisionID else {
            deviceSyncState = .blocked
            return
        }
        let rebased = IOSPendingDeviceSyncConflictResolution(
            key: identity.syncKey,
            conflict: conflict,
            content: resolution.content
        )
        do {
            try await runtime.mergeRecoveryStore.save(
                IOSDeviceSyncMergeRecoveryRecord(
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
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> IOSDeviceSyncEpisodeIdentity? {
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
            let identityAfterInstall: IOSDeviceSyncEpisodeIdentity
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
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) async -> IOSDeviceSyncInstallResult {
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  !isDocumentTransitionInProgress else { return .failed }
            isDocumentTransitionInProgress = true
            guard editorCommandSession.prepareForDocumentTransition() else {
                isDocumentTransitionInProgress = false
                return .failed
            }
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                isDocumentTransitionInProgress = false
            }

            guard let committedContent = capturedCommittedContent(for: expectedIdentity) else { return .failed }
            if document.episode(expectedIdentity.editingToken.episodeID)?.episode.content != committedContent {
                document.updateEpisodeContent(
                    committedContent,
                    for: expectedIdentity.editingToken.episodeID,
                    in: expectedIdentity.editingToken.chapterID
                )
            }
            saveCoordinator.markDirty()

            do {
                let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    guard deviceSyncContextIsCurrent(expectedIdentity),
                          let remote = grant.snapshot.head else { return SyncContentDigest?.none }
                    try remote.validate()
                    guard remote.key == expectedIdentity.syncKey else {
                        throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
                    }
                    document.updateEpisodeContent(
                        remote.content,
                        for: expectedIdentity.editingToken.episodeID,
                        in: expectedIdentity.editingToken.chapterID
                    )
                    saveCoordinator.markDirty()
                    advanceEditorContentGeneration()
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
        expectedEditingToken: IOSEpisodeEditingToken
    ) async {
        guard deviceSyncState == .writer || deviceSyncState == .offlineLocal,
              let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity.editingToken == expectedEditingToken,
              let client = deviceSyncClient(for: identity) else { return }

        deviceSyncTransferState = .uploading
        let recordedState = await documentOperationGate.perform { [weak self] () -> EpisodeSyncState? in
            guard let self,
                  deviceSyncContextIsCurrent(identity),
                  document.episode(identity.editingToken.episodeID)?.episode.content == content,
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
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) async throws -> EpisodeSyncState {
        let first = try await client.coordinator.synchronize()
        guard let runtime = deviceSyncRuntime,
              !Task.isCancelled,
              deviceSyncContextIsCurrent(expectedIdentity),
              ownsDeviceSyncAuthority(in: first, client: client, runtime: runtime),
              case .localChanges = first else { return first }

        return try await client.coordinator.synchronize()
    }

    private func installAuthorityGrant(
        _ grant: EpisodeAuthorityGrant,
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity,
        progressState: IOSDeviceSyncUIState
    ) async -> Bool {
        guard let runtime = deviceSyncRuntime else { return false }
        deviceSyncState = progressState
        let installedDigest = await documentOperationGate.perform { [weak self] in
            guard let self else { return IOSDeviceSyncInstallResult.failed }
            return await installAuthorityGrantSerially(
                grant,
                client: client,
                expectedIdentity: expectedIdentity
            )
        }

        switch installedDigest {
        case .failed:
            if !deviceSyncContextIsCurrent(expectedIdentity) {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
            }
            return false
        case let .alreadyInstalled(digest):
            guard deviceSyncContextIsCurrent(expectedIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            return await confirmAuthorityGrant(
                grant,
                installedDigest: digest,
                client: client,
                expectedIdentity: expectedIdentity,
                runtime: runtime
            )
        case let .installed(digest):
            guard let currentIdentity = currentDeviceSyncIdentityAfterSingleInstall(from: expectedIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            return await confirmAuthorityGrant(
                grant,
                installedDigest: digest,
                client: client,
                expectedIdentity: currentIdentity,
                runtime: runtime
            )
        }
    }

    private func confirmAuthorityGrant(
        _ grant: EpisodeAuthorityGrant,
        installedDigest: SyncContentDigest?,
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Bool {
        do {
            let state = try await client.coordinator.confirmAuthorityInstall(
                grant,
                installedRemoteDigest: installedDigest
            )
            guard deviceSyncContextIsCurrent(expectedIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            applyDeviceSyncState(state, client: client, expectedIdentity: expectedIdentity)
            return true
        } catch {
            // exact remote本文は既にpackageへ保存済みだが、authorityはackされていない。
            guard deviceSyncContextIsCurrent(expectedIdentity) else {
                await relinquishStaleDeviceSyncAuthority(client: client, runtime: runtime)
                return false
            }
            let latest = await client.coordinator.state
            applyDeviceSyncState(latest, client: client, expectedIdentity: expectedIdentity)
            if case .conflicted = latest {
                return true
            }
            deviceSyncState = .readOnly
            return true
        }
    }

    private func installAuthorityGrantSerially(
        _ grant: EpisodeAuthorityGrant,
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) async -> IOSDeviceSyncInstallResult {
        guard deviceSyncContextIsCurrent(expectedIdentity), !isDocumentTransitionInProgress else { return .failed }
        isDocumentTransitionInProgress = true
        guard editorCommandSession.prepareForDocumentTransition() else {
            isDocumentTransitionInProgress = false
            return .failed
        }
        defer {
            editorCommandSession.resumeAfterDocumentTransition()
            isDocumentTransitionInProgress = false
        }

        guard let localContent = capturedCommittedContent(for: expectedIdentity) else { return .failed }
        if document.episode(expectedIdentity.editingToken.episodeID)?.episode.content != localContent {
            document.updateEpisodeContent(
                localContent,
                for: expectedIdentity.editingToken.episodeID,
                in: expectedIdentity.editingToken.chapterID
            )
        }
        saveCoordinator.markDirty()

        do {
            let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard deviceSyncContextIsCurrent(expectedIdentity) else {
                    return IOSDeviceSyncInstallResult.failed
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
                    return IOSDeviceSyncInstallResult.failed
                }
                if let remote {
                    document.updateEpisodeContent(
                        remote.content,
                        for: expectedIdentity.editingToken.episodeID,
                        in: expectedIdentity.editingToken.chapterID
                    )
                }
                saveCoordinator.markDirty()
                advanceEditorContentGeneration()
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
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) async {
        guard deviceSyncContextIsCurrent(expectedIdentity) else { return }
        deviceSyncState = .syncing
        let installResult = await documentOperationGate.perform { [weak self] in
            guard let self else { return IOSDeviceSyncInstallResult.failed }
            return await installFenceObservationSerially(
                observation,
                client: client,
                expectedIdentity: expectedIdentity
            )
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

    private func installFenceObservationSerially(
        _ observation: EpisodeFenceObservation,
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) async -> IOSDeviceSyncInstallResult {
        guard deviceSyncContextIsCurrent(expectedIdentity), !isDocumentTransitionInProgress else { return .failed }
        guard let snapshot = fencedSnapshot(from: observation) else { return .failed }
        isDocumentTransitionInProgress = true
        guard editorCommandSession.prepareForDocumentTransition() else {
            isDocumentTransitionInProgress = false
            return .failed
        }
        defer {
            editorCommandSession.resumeAfterDocumentTransition()
            isDocumentTransitionInProgress = false
        }

        guard let localContent = capturedCommittedContent(for: expectedIdentity) else { return .failed }
        if document.episode(expectedIdentity.editingToken.episodeID)?.episode.content != localContent {
            document.updateEpisodeContent(
                localContent,
                for: expectedIdentity.editingToken.episodeID,
                in: expectedIdentity.editingToken.chapterID
            )
        }
        saveCoordinator.markDirty()

        do {
            let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                _ = try await client.coordinator.preserveLocalFork(
                    content: localContent,
                    createdAt: deviceSyncRuntime?.now() ?? Date(),
                    for: observation
                )
                guard deviceSyncContextIsCurrent(expectedIdentity) else { return SyncContentDigest?.none }
                let remote = snapshot.head
                if let remote {
                    try remote.validate()
                    guard remote.key == expectedIdentity.syncKey else {
                        throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
                    }
                    document.updateEpisodeContent(
                        remote.content,
                        for: expectedIdentity.editingToken.episodeID,
                        in: expectedIdentity.editingToken.chapterID
                    )
                }
                saveCoordinator.markDirty()
                advanceEditorContentGeneration()
                updateDeviceSyncIdentityAfterRemoteInstall(expectedIdentity)
                return remote?.contentDigest
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

    private func installResolvedConflictContent(
        _ content: String,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) async -> Bool {
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  !isDocumentTransitionInProgress else { return false }
            isDocumentTransitionInProgress = true
            guard editorCommandSession.prepareForDocumentTransition() else {
                isDocumentTransitionInProgress = false
                return false
            }
            defer {
                editorCommandSession.resumeAfterDocumentTransition()
                isDocumentTransitionInProgress = false
            }
            saveCoordinator.markDirty()
            let result = await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard deviceSyncContextIsCurrent(expectedIdentity) else { return false }
                document.updateEpisodeContent(
                    content,
                    for: expectedIdentity.editingToken.episodeID,
                    in: expectedIdentity.editingToken.chapterID
                )
                saveCoordinator.markDirty()
                advanceEditorContentGeneration()
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

    private func fencedSnapshot(from observation: EpisodeFenceObservation) -> EpisodeRemoteSnapshot? {
        switch observation {
        case .authorityValid:
            nil
        case let .authorityLost(snapshot), let .remoteAdvanced(snapshot):
            snapshot
        }
    }

    private func capturedCommittedContent(for identity: IOSDeviceSyncEpisodeIdentity) -> String? {
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(content):
            content
        case .notActive:
            document.episode(identity.editingToken.episodeID)?.episode.content
        case .compositionInProgress:
            nil
        }
    }

    private func installedContentDigest(
        for grant: EpisodeAuthorityGrant,
        identity: IOSDeviceSyncEpisodeIdentity
    ) -> SyncContentDigest? {
        guard let remote = grant.snapshot.head else { return nil }
        guard let content = document.episode(identity.editingToken.episodeID)?.episode.content else { return nil }
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

    private func updateDeviceSyncIdentityAfterRemoteInstall(_ previous: IOSDeviceSyncEpisodeIdentity) {
        guard let editingToken = currentEpisodeEditingToken else { return }
        let updated = IOSDeviceSyncEpisodeIdentity(
            editingToken: editingToken,
            structureDigest: previous.structureDigest,
            localWorkingCopyID: previous.localWorkingCopyID,
            syncKey: previous.syncKey
        )
        activeDeviceSyncIdentity = updated
        resolvedDeviceSyncLookupIdentity = IOSDeviceSyncLookupIdentity(
            editingToken: editingToken,
            structureDigest: previous.structureDigest
        )
    }

    func applyDeviceSyncState(
        _ state: EpisodeSyncState,
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
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
        client: IOSDeviceSyncClient,
        runtime: IOSDeviceSyncRuntime
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
        client: IOSDeviceSyncClient,
        runtime: IOSDeviceSyncRuntime
    ) -> Bool {
        context.lease?.authority.holderReplicaID == runtime.replicaID &&
            context.lease?.authority.holderSessionID == client.sessionID
    }

    private func relinquishStaleDeviceSyncAuthority(
        client: IOSDeviceSyncClient,
        runtime: IOSDeviceSyncRuntime
    ) async {
        if let grant = await client.coordinator.authorityGrantAwaitingInstall {
            _ = try? await client.coordinator.abandonAuthorityGrant(grant)
            return
        }
        let state = await client.coordinator.state
        guard ownsDeviceSyncAuthority(in: state, client: client, runtime: runtime) else { return }
        _ = try? await client.coordinator.releaseEditingAuthority()
    }

    func deviceSyncClient(for identity: IOSDeviceSyncEpisodeIdentity) -> IOSDeviceSyncClient? {
        deviceSyncClients[
            IOSDeviceSyncClientKey(
                localWorkingCopyID: identity.localWorkingCopyID,
                syncKey: identity.syncKey
            )
        ]
    }

    func deviceSyncContextIsCurrent(_ identity: IOSDeviceSyncEpisodeIdentity) -> Bool {
        activeDeviceSyncIdentity == identity &&
            currentDeviceSyncLookupIdentity == IOSDeviceSyncLookupIdentity(
                editingToken: identity.editingToken,
                structureDigest: identity.structureDigest
            )
    }

    private func currentDeviceSyncIdentityAfterSingleInstall(
        from previous: IOSDeviceSyncEpisodeIdentity
    ) -> IOSDeviceSyncEpisodeIdentity? {
        guard let current = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(current),
              current.editingToken.documentSession == previous.editingToken.documentSession,
              current.editingToken.chapterID == previous.editingToken.chapterID,
              current.editingToken.episodeID == previous.editingToken.episodeID,
              current.localWorkingCopyID == previous.localWorkingCopyID,
              current.syncKey == previous.syncKey,
              current.editingToken.editorContentGeneration ==
              previous.editingToken.editorContentGeneration &+ 1 else { return nil }
        return current
    }

    private func currentDeviceSyncIdentityAfterConflictInstall(
        from previous: IOSDeviceSyncEpisodeIdentity,
        installationSucceeded: Bool
    ) -> IOSDeviceSyncEpisodeIdentity? {
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
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime,
        updatesJournalLocal: Bool = false
    ) async -> Bool {
        if pendingDeviceSyncConflictResolution?.key == expectedIdentity.syncKey {
            return true
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            guard let committed = capturedCommittedContent(for: expectedIdentity) else { return false }
            let digest = SyncContentDigest(content: committed)
            guard digest != conflict.local.contentDigest,
                  digest != conflict.remote.contentDigest else { return true }
            if document.episode(expectedIdentity.editingToken.episodeID)?.episode.content != committed {
                document.updateEpisodeContent(
                    committed,
                    for: expectedIdentity.editingToken.episodeID,
                    in: expectedIdentity.editingToken.chapterID
                )
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
                reconciledConflict = conflict
            }
            let resolution = IOSPendingDeviceSyncConflictResolution(
                key: expectedIdentity.syncKey,
                conflict: reconciledConflict,
                content: committed
            )
            do {
                try await runtime.mergeRecoveryStore.save(
                    IOSDeviceSyncMergeRecoveryRecord(
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
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> IOSDeviceSyncEpisodeIdentity? {
        let record: IOSDeviceSyncMergeRecoveryRecord
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
                pendingDeviceSyncConflictResolution = IOSPendingDeviceSyncConflictResolution(
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
                let rebasedRecord = IOSDeviceSyncMergeRecoveryRecord(
                    localWorkingCopyID: record.localWorkingCopyID,
                    key: record.key,
                    conflict: conflict,
                    content: record.content
                )
                try await runtime.mergeRecoveryStore.save(rebasedRecord)
                pendingDeviceSyncConflictResolution = IOSPendingDeviceSyncConflictResolution(
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
        _ record: IOSDeviceSyncMergeRecoveryRecord,
        matches conflict: EpisodeConflict
    ) -> Bool {
        Set([conflict.local.revisionID, conflict.remote.revisionID]) == record.parentRevisionIDs
    }

    private func mergeRecoveryRecord(
        _ record: IOSDeviceSyncMergeRecoveryRecord,
        matches revision: EpisodeRevision
    ) -> Bool {
        Set(revision.parentRevisionIDs) == record.parentRevisionIDs &&
            revision.contentDigest == record.contentDigest
    }

    private func mergeRecoveryRecord(
        _ record: IOSDeviceSyncMergeRecoveryRecord,
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
        for resolution: IOSPendingDeviceSyncConflictResolution,
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
        resolution: IOSPendingDeviceSyncConflictResolution
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
}

private enum IOSDeviceSyncInstallResult: Sendable {
    case failed
    case alreadyInstalled(SyncContentDigest?)
    case installed(SyncContentDigest?)
}
