import AppKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    /// CloudKitを待たず、検証済みの端末内inventoryだけで作品棚を表示する。
    /// ここがmacOSのforeground/startup laneの完了境界であり、remote catalogは
    /// このメソッドの後に別Taskで開始する。
    @discardableResult
    func refreshLocalStartupLibrary() async -> Bool {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              case let .documentSelection(current) = startupState,
              current.presentation == .cloudLibrary else { return false }

        startupLibraryRefreshGeneration &+= 1
        let generation = startupLibraryRefreshGeneration
        let expectedSession = documentSessionToken
        if current.works.isEmpty {
            permitsCloudLibraryMutation = false
        }
        mayAttemptInitialCloudPublish = false

        do {
            let local = try await StartupLibraryLoader(repository: repository)
                .loadVerifiedLocalLibrary(using: library, now: runtime.now())
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return false
            }
            let resumableWorkIDs = await library.offlineResumableRemoteOpenWorkIDs()
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return false
            }
            permitsCloudLibraryMutation = true
            startupRemoteLibraryEntries = [:]
            lastStartupLibraryConnection = current.connection
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: StartupLibraryProjection.addOfflineResumableRows(
                        resumableWorkIDs,
                        to: local.rows
                    ).sorted(by: StartupLibraryProjection.sort),
                    connection: current.connection,
                    isLoading: false
                )
            )
            return true
        } catch {
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return false
            }
            permitsCloudLibraryMutation = false
            startupRemoteLibraryEntries = [:]
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .unavailable(message: "このMacの作品情報を安全に確認できませんでした。")
                )
            )
            return false
        }
    }

    /// cached rowsを先に残し、remote refreshは同じ棚へmergeする。標準runtimeで
    /// recent path fallbackを一瞬でも表示しない。
    func refreshStartupLibrary() async {
        if usesSnapshotSyncRuntime {
            await refreshSnapshotLibrary()
            return
        }
        if let startupLibraryRefreshTask {
            await startupLibraryRefreshTask.value
        }
        if let startupLibraryRefreshTask {
            await startupLibraryRefreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performStartupLibraryRefresh()
        }
        startupLibraryRefreshTask = task
        await task.value
        startupLibraryRefreshTask = nil
    }

    func scheduleStartupLibraryRemoteRefreshIfNeeded() {
        guard (deviceSyncRuntime?.library != nil || usesSnapshotSyncRuntime),
              case let .documentSelection(context) = startupState,
              context.presentation == .cloudLibrary,
              startupLibraryRefreshTask == nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshStartupLibrary()
        }
    }

    /// Remote catalog is deliberately a background lane. The verified local
    /// shelf remains visible and usable for the whole duration of this method.
    private func performStartupLibraryRefresh() async {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library,
              case let .documentSelection(current) = startupState,
              current.presentation == .cloudLibrary else { return }

        startupLibraryRefreshGeneration &+= 1
        let generation = startupLibraryRefreshGeneration
        let expectedSession = documentSessionToken
        let priorRows = current.works
        // A previously verified local shelf remains writable while this remote
        // refresh is in flight. Only an actual local verification failure
        // revokes the local mutation capability below.
        if priorRows.isEmpty {
            permitsCloudLibraryMutation = false
        }
        mayAttemptInitialCloudPublish = false
        startupState = .documentSelection(
            StartupDocumentSelectionContext(
                works: priorRows,
                connection: current.connection,
                isLoading: false
            )
        )

        let local: StartupVerifiedLocalLibrarySnapshot
        do {
            local = try await StartupLibraryLoader(repository: repository)
                .loadVerifiedLocalLibrary(using: library, now: runtime.now())
        } catch {
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            permitsCloudLibraryMutation = false
            startupRemoteLibraryEntries = [:]
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    // root/registry validation failureは旧accountのremote titleも含め
                    // fail-closedで破棄し、端末内packageを確認できたとはclaimしない。
                    works: [],
                    connection: .unavailable(message: "このMacの作品情報を安全に確認できませんでした。")
                )
            )
            return
        }

        guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
            return
        }
        startupState = .documentSelection(
            StartupDocumentSelectionContext(
                works: local.rows.sorted(by: StartupLibraryProjection.sort),
                connection: current.connection,
                isLoading: false
            )
        )

        // Local inventory has been verified. Local new/import may proceed even
        // while the account and remote catalog are unavailable.
        permitsCloudLibraryMutation = true

        let resumableWorkIDs = await library.offlineResumableRemoteOpenWorkIDs()
        guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
            return
        }

        do {
            var remote = try await library.loadRemoteLibrary()
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            guard startupLibraryRefreshIsCurrent(
                generation,
                expectedSession: expectedSession
            ) else { return }
            let didPublish = await retryAccountScopedPendingPublications(
                local: local,
                remote: remote,
                library: library
            )
            if didPublish {
                remote = try await library.loadRemoteLibrary()
                guard startupLibraryRefreshIsCurrent(
                    generation,
                    expectedSession: expectedSession
                ) else { return }
            }
            // local inventoryとaccount状態を同じrefresh generationで確認した後だけ
            // new/importを許可する。accountRequiredでもlocal-only作成は可能だが、
            // initial publishは別accountへ漏らさない。
            permitsCloudLibraryMutation = true
            mayAttemptInitialCloudPublish = remote.connection == .available
                || remote.connection == .offline
            lastStartupLibraryConnection = StartupLibraryProjection.connection(remote.connection)
            let merged = await mergeStartupLibrary(
                local: local,
                remote: remote,
                resumableWorkIDs: resumableWorkIDs,
                library: library
            )
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: merged.sorted(by: StartupLibraryProjection.sort),
                    connection: StartupLibraryProjection.connection(remote.connection)
                )
            )
        } catch {
            guard startupLibraryRefreshIsCurrent(generation, expectedSession: expectedSession) else {
                return
            }
            DeviceSyncLog.event("catalog refresh failed", error: error)
            startupRemoteLibraryEntries = [:]
            // local inventory/rootはこのgenerationで検証済み。remote catalogの
            // 読込失敗はuploadを止めるが、端末内の新規・Importまで止めない。
            permitsCloudLibraryMutation = true
            mayAttemptInitialCloudPublish = false
            lastStartupLibraryConnection = .unavailable(
                message: "サーバーの作品を更新できませんでした。"
            )
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: StartupLibraryProjection.addOfflineResumableRows(
                        resumableWorkIDs,
                        to: local.rows
                    ).sorted(by: StartupLibraryProjection.sort),
                    connection: lastStartupLibraryConnection
                )
            )
        }
    }

    private func startupLibraryRefreshIsCurrent(
        _ generation: UInt64,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard startupLibraryRefreshGeneration == generation,
              documentSessionToken == expectedSession,
              case let .documentSelection(context) = startupState,
              context.presentation == .cloudLibrary else { return false }
        return true
    }

    private func mergeStartupLibrary(
        local: StartupVerifiedLocalLibrarySnapshot,
        remote: DeviceSyncRemoteLibrarySnapshot,
        resumableWorkIDs: [SyncWorkID],
        library: DeviceSyncLibraryRuntime
    ) async -> [StartupLibraryWork] {
        var rows = Dictionary(uniqueKeysWithValues: local.items.map { ($0.key, $0.value.row) })
        var exactEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]

        if remote.connection == .accountRequired || remote.connection == .differentAccount {
            for (workID, localItem) in local.items
                where localItem.record?.state == .remoteOpenPending
                && localItem.attestation == nil {
                // Account-independent App registryだけに残った未download intentは、
                // account identityを再確認できるまで存在自体を棚へ出さない。
                rows.removeValue(forKey: workID)
            }
        }

        for remoteItem in remote.entries {
            let entry = remoteItem.work
            exactEntries[entry.workID] = entry
            if let localItem = local.items[entry.workID],
               let attestation = localItem.attestation {
                let availability: StartupLibraryWorkAvailability
                if localItem.row.availability == .needsReview {
                    availability = .needsReview
                } else if attestation.matches(entry),
                          remoteItem.availability == .locallyBound,
                          await library.hasCompletedRemoteOpenLocally(entry) {
                    // Covers both remote bootstrap→registry mark kill and new-work
                    // publish→registry mark kill. The checkmark appears only after
                    // Domain exact journal truth and App registry durability agree.
                    do {
                        try await library.markSynced(entry.workID, entry)
                        availability = .cachedRemote
                    } catch {
                        availability = .unavailable
                    }
                } else if localItem.record?.state == .remoteOpenPending {
                    // Domainのimmutable pending revisionを先に完了し、moving headへは
                    // 通常WorkSyncで追随する。ここでcurrent catalogへ偽装しない。
                    availability = localItem.row.availability
                } else if !entry.hasWorkRevisionHead {
                    // D-071: Note identity is catalog truth. hasCompletedRemoteOpenLocally
                    // is WorkControl-head specific and stays false after first save.
                    if localItem.record?.state == .needsReview {
                        availability = .needsReview
                    } else if attestation.matches(entry),
                              remoteItem.availability == .locallyBound {
                        do {
                            try await library.markSynced(entry.workID, entry)
                            availability = .cachedRemote
                        } catch {
                            availability = .localPending
                        }
                    } else {
                        availability = .localPending
                    }
                } else if attestation.matches(entry) {
                    let exactAck = localItem.record?.acknowledgedRemote == entry
                    availability = remoteItem.availability == .locallyBound && exactAck
                        ? .cachedRemote
                        : localItem.record?.state == .needsReview ? .needsReview : .localPending
                } else {
                    availability = localItem.record?.state == .publishPending
                        ? .localPending
                        : .needsReview
                }
                rows[entry.workID] = StartupLibraryWork(
                    reference: .cloudWork(entry.workID.rawValue),
                    title: attestation.titleProjection,
                    updatedAt: attestation.updatedAt,
                    availability: availability,
                    isTitleTruncated: attestation.fullTitleUTF8ByteCount > attestation.titleProjection.utf8.count
                )
            } else if rows[entry.workID]?.availability != .unavailable {
                // Account identityを証明できないsnapshotに含まれたremote-only行は
                // titleを一般化するだけでなく棚から隔離する。端末内packageまたは
                // same-accountのdurable resume identityがある行は別経路で残る。
                // D-071 Note catalogはnil-headでもWorkIDの存在がdownload条件である。
                guard remote.connection != .accountRequired,
                      remote.connection != .differentAccount else { continue }
                let canResume: Bool = if remoteItem.availability == .remoteDownloadPending {
                    await library.canResumeRemoteOpenOffline(entry.workID)
                } else {
                    false
                }
                rows[entry.workID] = StartupLibraryWork(
                    reference: .cloudWork(entry.workID.rawValue),
                    title: entry.title,
                    updatedAt: entry.headClientCreatedAt,
                    availability: canResume ? .remotePending : .remoteOnly,
                    isTitleTruncated: entry.isTitleTruncated
                )
            }
        }

        if remote.connection == .available {
            let listedWorkIDs = Set(remote.entries.map(\.work.workID))
            for (workID, localItem) in local.items
                where localItem.row.availability == .cachedRemote
                && !listedWorkIDs.contains(workID) {
                // 接続中のcurrent catalogに作品が無いのに、過去のreceiptだけで
                // 「同期済み」とは表示しない。hard delete／malformed control／
                // account-side omissionを区別できるまではlocal copyを保持してreviewへ。
                rows[workID] = StartupLibraryWork(
                    reference: localItem.row.reference,
                    title: localItem.row.title,
                    updatedAt: localItem.row.updatedAt,
                    availability: .cloudUnavailable,
                    isTitleTruncated: localItem.row.isTitleTruncated
                )
            }
        }
        startupRemoteLibraryEntries = exactEntries
        return StartupLibraryProjection.addOfflineResumableRows(
            resumableWorkIDs,
            to: Array(rows.values)
        )
    }

    /// Verified local registryの`publishPending`とcanonical local bindingの
    /// 両方が揃うsame-account workだけを自動再送する。WorkControlはheadが
    /// nilの間catalogへ出ないため、remote rowの存在を再送条件にしない。
    private func retryAccountScopedPendingPublications(
        local: StartupVerifiedLocalLibrarySnapshot,
        remote: DeviceSyncRemoteLibrarySnapshot,
        library: DeviceSyncLibraryRuntime
    ) async -> Bool {
        guard remote.connection == .available,
              !isStartupLibraryOperationInProgress,
              let portableRepository = repository as? PortableDocumentPackageRepository else {
            return false
        }
        var didPublish = false
        for localItem in local.items.values {
            guard localItem.row.availability == .localPending,
                  localItem.record?.state == .publishPending,
                  let record = localItem.record,
                  let expected = localItem.attestation,
                  await library.hasLocalPublishAuthority(
                      record.workID,
                      record.expectedDocumentID
                  ) else { continue }
            let alreadyOnICloud: Bool = if let remoteItem = remote.entries.first(where: {
                $0.work.workID == record.workID
            }),
                remoteItem.availability == .locallyBound,
                expected.matches(remoteItem.work) {
                await library.hasCompletedRemoteOpenLocally(remoteItem.work)
                    || !remoteItem.work.hasWorkRevisionHead
            } else {
                false
            }
            if alreadyOnICloud {
                // Initial publish完了→App registry acknowledgement前の窓は、
                // exact remote/domain proofをmerge側でmarkSyncedする。ここで
                // 同じrevisionをhidden coordinatorへ二重送信しない。
                continue
            }
            do {
                try await library.validateInstalledPackage(record.workID)
                let url = try await library.packageURL(record.workID)
                let document = try await portableRepository.validatePortablePackage(at: url)
                let readback = try DeviceSyncLocalPackageAttestation(
                    document: document,
                    updatedAt: expected.updatedAt
                )
                guard readback == expected,
                      document.id == record.expectedDocumentID else { continue }
                let isActiveDocument = startupState.isReady
                    && documentURL.standardizedFileURL == url.standardizedFileURL
                if isActiveDocument {
                    try await library.publishNewWork(record.workID, document, url)
                } else {
                    try await library.resumeInitialWorkPublication(record.workID, document, url)
                }
                didPublish = true
            } catch {
                continue
            }
        }
        return didPublish
    }

    /// Chooserを開いていない間も、remote signal／foreground／wakeを契機に
    /// account-scoped pending creationだけを再送する。active document/sessionへ
    /// remote内容を注入せず、package readbackとWorkIDだけで処理する。
    func retryAccountScopedPendingPublicationsInBackground() async {
        guard let runtime = deviceSyncRuntime,
              let library = runtime.library else { return }
        if let pendingLibraryRetryTask {
            await pendingLibraryRetryTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let local = try await StartupLibraryLoader(repository: repository)
                    .loadVerifiedLocalLibrary(using: library, now: runtime.now())
                let remote = try await library.loadRemoteLibrary()
                mayAttemptInitialCloudPublish = remote.connection == .available
                    || remote.connection == .offline
                lastStartupLibraryConnection = StartupLibraryProjection.connection(remote.connection)
                _ = await retryAccountScopedPendingPublications(
                    local: local,
                    remote: remote,
                    library: library
                )
            } catch {
                mayAttemptInitialCloudPublish = false
            }
        }
        pendingLibraryRetryTask = task
        await task.value
        pendingLibraryRetryTask = nil
    }
}
