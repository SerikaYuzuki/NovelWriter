import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

struct IOSPrivateDocumentID: Hashable, Sendable {
    let packageName: String
    let workID: WorkID?

    init(packageName: String) {
        self.packageName = packageName
        let basename = packageName.replacingOccurrences(of: ".novelpkg", with: "")
        workID = UUID(uuidString: basename).map { WorkID($0) }
    }

    init(workID: WorkID) {
        packageName = workID.rawValue.uuidString
        self.workID = workID
    }
}

struct IOSDocumentSessionToken: Hashable, Sendable {
    let workingCopyID: IOSPrivateDocumentID
    let generation: UInt64

    /// The sync owner is explicit even while the package-name compatibility
    /// value remains available to navigation code and retired fixtures.
    var workID: WorkID? {
        workingCopyID.workID
    }
}

enum IOSDocumentLibraryAvailability: Equatable, Sendable {
    case available, unreadable, local, server, pending, offline, conflict
}

struct IOSDocumentLibraryItem: Identifiable, Equatable, Sendable {
    let id: IOSPrivateDocumentID
    let title: String
    let chapterCount: Int
    let episodeCount: Int
    let characterCount: Int
    let modificationDate: Date?
    let availability: IOSDocumentLibraryAvailability
    let errorMessage: String?
}

extension IOSDocumentStore {
    var exposesAccountScopedSyncV2Items: Bool {
        if case .signedIn = authUIState {
            return true
        }
        return false
    }

    /// Parked works are deliberately local-only, but unlike an unbound work
    /// they must remain visible after sign-out/account switch.  They never
    /// become an account-scoped remote projection.
    var exposesParkedSyncV2Items: Bool {
        true
    }

    var usesSnapshotSyncRuntime: Bool {
        snapshotSyncV2Application != nil
    }

    var canExplicitlySyncCurrentWork: Bool {
        guard snapshotSyncV2Application != nil,
              startupState == .ready,
              !isSyncV2AccountTransitionActive,
              authSession != nil,
              case .signedIn = authUIState,
              let workID = syncV2ActiveWorkID else { return false }
        return syncV2LibraryItems.first(where: { $0.workID == workID })?.accountState == .active
    }

    /// Local snapshot restore is distinct from remote sync. A parked work may
    /// use a snapshot ID already known to the local SQLite history, while it
    /// must never expose a remote sync/adoption action.
    var canRestoreLocalSnapshot: Bool {
        snapshotSyncV2Application != nil &&
            startupState == .ready &&
            syncV2ActiveWorkID != nil &&
            !isDocumentTransitionInProgress &&
            !isSyncV2AccountTransitionActive
    }

    /// Local history remains available for a parked/signed-out Work.  This
    /// is intentionally separate from `canExplicitlySyncCurrentWork`: the
    /// latter gates account-scoped remote work, while history can be read from
    /// the local SQLite lane without an active account.
    var canRefreshSnapshotHistory: Bool {
        snapshotSyncV2Application != nil &&
            startupState == .ready &&
            syncV2ActiveWorkID != nil &&
            !isDocumentTransitionInProgress &&
            !isSyncV2AccountTransitionActive
    }

    var isCurrentWorkParked: Bool {
        guard let workID = syncV2ActiveWorkID else { return false }
        return syncV2LibraryItems.first(where: { $0.workID == workID })?.accountState
            == .parkedDifferentAccount
    }

    var isExplicitSyncInFlight: Bool {
        isSnapshotSyncInFlight
    }

    @discardableResult
    func refreshLibrary() async -> Bool {
        guard !isSyncV2AccountTransitionActive else { return false }
        do {
            guard try await reloadLibraryItems() else { return false }
            // The local shelf is authoritative for launch/open.  Catalog I/O
            // is a deferred projection refresh and never gates the shelf.
            Task { @MainActor [weak self] in
                _ = await self?.refreshRemoteCatalog(reset: true)
            }
            return true
        } catch {
            operationErrorMessage = "作品一覧を読み込めませんでした。"
            return false
        }
    }

    @discardableResult
    func reloadLibraryItems() async throws -> Bool {
        guard !isSyncV2AccountTransitionActive else { return false }
        guard let application = snapshotSyncV2Application else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        let expectedAccountScope = snapshotSyncV2AccountScope
        libraryRefreshGeneration &+= 1
        let refreshGeneration = libraryRefreshGeneration
        // A local shelf refresh supersedes any older remote page. Its task may
        // finish, but the generation CAS below prevents it from publishing.
        syncV2RemoteCatalogIsLoading = false
        let projection = try await application.library()
        return applySnapshotSyncV2LibraryProjection(
            projection,
            expectedAccountScope: expectedAccountScope,
            refreshGeneration: refreshGeneration
        )
    }

    @discardableResult
    func applySnapshotSyncV2LibraryProjection(
        _ projection: SyncV2LibraryProjection,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        refreshGeneration: UInt64
    ) -> Bool {
        guard !isSyncV2AccountTransitionActive,
              libraryRefreshGeneration == refreshGeneration,
              snapshotSyncV2AccountScope == expectedAccountScope else { return false }
        let localItems = projection.items.filter { item in
            if item.accountState == .parkedDifferentAccount {
                return exposesParkedSyncV2Items
            }
            return exposesAccountScopedSyncV2Items || item.accountState == .unbound
        }
        syncV2LibraryItems = mergeRemoteCatalog(
            into: localItems,
            catalog: exposesAccountScopedSyncV2Items ? syncV2RemoteCatalogItems : []
        )
        libraryItems = []
        verifiedPrivateDocumentIDs = []
        return true
    }

    /// Reads the account-scoped remote catalog page.  The runtime/provider is
    /// responsible for account fencing; this store only retains the opaque
    /// WorkID/title/head projection for the shelf.
    @discardableResult
    func refreshRemoteCatalog(reset: Bool = true) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              exposesAccountScopedSyncV2Items,
              let application = snapshotSyncV2Application else { return false }
        guard !syncV2RemoteCatalogIsLoading else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        libraryRefreshGeneration &+= 1
        let refreshGeneration = libraryRefreshGeneration
        let cursor = reset ? nil : syncV2RemoteCatalogCursor
        let existingItems = reset ? [] : syncV2RemoteCatalogItems
        syncV2RemoteCatalogIsLoading = true
        syncV2RemoteCatalogError = nil
        defer {
            if libraryRefreshGeneration == refreshGeneration {
                syncV2RemoteCatalogIsLoading = false
            }
        }
        do {
            let page = try await application.refreshRemoteCatalog(
                cursor: cursor,
                pageSize: 100
            )
            guard !isSyncV2AccountTransitionActive,
                  libraryRefreshGeneration == refreshGeneration,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            var rows = Dictionary(
                uniqueKeysWithValues: existingItems.map { ($0.workID, $0) }
            )
            for item in page.items {
                rows[item.workID] = item
            }
            let remoteItems = rows.values.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let projection = try await application.library()
            return applySnapshotSyncV2RemoteCatalogPage(
                remoteItems: remoteItems,
                nextCursor: page.nextCursor,
                localProjection: projection,
                expectedAccountScope: expectedAccountScope,
                refreshGeneration: refreshGeneration
            )
        } catch {
            if !isSyncV2AccountTransitionActive,
               libraryRefreshGeneration == refreshGeneration,
               snapshotSyncV2AccountScope == expectedAccountScope {
                syncV2RemoteCatalogError = error.localizedDescription
            }
            return false
        }
    }

    @discardableResult
    func applySnapshotSyncV2RemoteCatalogPage(
        remoteItems: [SyncV2RemoteCatalogEntry],
        nextCursor: String?,
        localProjection: SyncV2LibraryProjection,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        refreshGeneration: UInt64
    ) -> Bool {
        guard !isSyncV2AccountTransitionActive,
              libraryRefreshGeneration == refreshGeneration,
              snapshotSyncV2AccountScope == expectedAccountScope else { return false }
        let localItems = localProjection.items.filter { item in
            if item.accountState == .parkedDifferentAccount {
                return exposesParkedSyncV2Items
            }
            return exposesAccountScopedSyncV2Items || item.accountState == .unbound
        }
        syncV2RemoteCatalogItems = remoteItems
        syncV2RemoteCatalogCursor = nextCursor
        syncV2LibraryItems = mergeRemoteCatalog(
            into: localItems,
            catalog: exposesAccountScopedSyncV2Items ? remoteItems : []
        )
        libraryItems = []
        verifiedPrivateDocumentIDs = []
        return true
    }

    @discardableResult
    func loadMoreRemoteCatalog() async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              syncV2RemoteCatalogCursor != nil else { return false }
        return await refreshRemoteCatalog(reset: false)
    }

    @discardableResult
    func refreshSnapshotHistory(for workID: WorkID, reset: Bool = true) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        historyRefreshGeneration &+= 1
        let refreshGeneration = historyRefreshGeneration
        let existingItems = reset || syncV2HistoryWorkID != workID
            ? [] : syncV2HistoryItems
        if reset || syncV2HistoryWorkID != workID {
            syncV2HistoryItems = []
            syncV2HistoryCursor = nil
            syncV2HistoryWorkID = workID
            syncV2HistoryLocalAvailability = .unavailable
            syncV2HistoryOnlineAvailability = .unavailable
            syncV2HistoryOnlineFailure = nil
        }
        let cursor = syncV2HistoryCursor
        do {
            let page = try await application.historyPage(
                workID: workID,
                cursor: cursor,
                pageSize: 100
            )
            return applySnapshotSyncV2HistoryPage(
                page,
                existingItems: existingItems,
                workID: workID,
                expectedAccountScope: expectedAccountScope,
                refreshGeneration: refreshGeneration
            )
        } catch {
            if !isSyncV2AccountTransitionActive,
               historyRefreshGeneration == refreshGeneration,
               syncV2HistoryWorkID == workID,
               snapshotSyncV2AccountScope == expectedAccountScope {
                syncV2HistoryOnlineFailure = (error as? SyncV2Failure) ?? .offline
            }
            return false
        }
    }

    @discardableResult
    func applySnapshotSyncV2HistoryPage(
        _ page: SyncV2HistoryPage,
        existingItems: [SyncV2HistoryItem],
        workID: WorkID,
        expectedAccountScope: IOSSnapshotSyncV2AccountScope,
        refreshGeneration: UInt64
    ) -> Bool {
        guard !isSyncV2AccountTransitionActive,
              historyRefreshGeneration == refreshGeneration,
              syncV2HistoryWorkID == workID,
              snapshotSyncV2AccountScope == expectedAccountScope else { return false }
        syncV2HistoryItems = existingItems + page.items
        syncV2HistoryCursor = page.nextCursor
        syncV2HistoryLocalAvailability = page.localAvailability
        syncV2HistoryOnlineAvailability = page.onlineAvailability
        syncV2HistoryOnlineFailure = page.onlineFailure
        return true
    }

    func mergeRemoteCatalog(
        into localItems: [SyncV2LibraryItem],
        catalog: [SyncV2RemoteCatalogEntry]
    ) -> [SyncV2LibraryItem] {
        var rows = Dictionary(uniqueKeysWithValues: localItems.map { ($0.workID, $0) })
        for remote in catalog {
            if let local = rows[remote.workID] {
                // A parked local copy is an explicit account boundary.  A
                // catalog row with the same WorkID must never turn it into a
                // cached/remote row or overwrite its local-only status.
                if local.accountState == .parkedDifferentAccount {
                    continue
                }
                rows[remote.workID] = SyncV2LibraryItem(
                    workID: local.workID,
                    title: local.title.isEmpty ? remote.title : local.title,
                    availability: .cached,
                    accountState: local.accountState,
                    localGeneration: local.localGeneration,
                    remoteHead: remote.head ?? local.remoteHead,
                    conflict: local.conflict,
                    remoteProgress: local.remoteProgress
                )
            } else {
                rows[remote.workID] = SyncV2LibraryItem(
                    workID: remote.workID,
                    title: remote.title,
                    availability: .remoteOnly,
                    accountState: .active,
                    remoteHead: remote.head
                )
            }
        }
        return rows.values.sorted { $0.workID.description < $1.workID.description }
    }

    @discardableResult
    func openPrivateDocument(id: IOSPrivateDocumentID) async -> Bool {
        guard !isSyncV2AccountTransitionActive else { return false }
        if snapshotSyncV2Application != nil, let workID = id.workID {
            if syncV2LibraryItems.first(where: { $0.workID == workID })?.availability == .remoteOnly {
                return await startRemoteOnlySnapshotSyncV2Open(workID: workID)
            }
            return await openSnapshotSyncV2(workID: workID.rawValue)
        }
        return false
    }

    func openRemoteOnly(workID: WorkID) async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              exposesAccountScopedSyncV2Items,
              syncV2LibraryItems.first(where: { $0.workID == workID })?.accountState
              != .parkedDifferentAccount else { return false }
        return await startRemoteOnlySnapshotSyncV2Open(workID: workID)
    }

    /// Explicitly promotes an unbound local Work into the signed-in account.
    /// Sign-in alone never adopts or uploads that Work; this action creates a
    /// new WorkID, opens it under the same document gate, and leaves the
    /// original unbound Work intact.
    @discardableResult
    func cloneActiveWorkIntoSignedInAccount() async -> Bool {
        guard !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application,
              let sourceWorkID = syncV2ActiveWorkID,
              let expectedSession = currentDocumentSessionToken,
              syncV2ParkedAccountID == nil,
              case .signedIn = authUIState,
              !syncV2AccountCloneInFlight else { return false }
        let expectedAccountScope = snapshotSyncV2AccountScope
        syncV2AccountCloneInFlight = true
        defer { syncV2AccountCloneInFlight = false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  !isSyncV2AccountTransitionActive,
                  currentDocumentSessionToken == expectedSession,
                  snapshotSyncV2AccountScope == expectedAccountScope else { return false }
            var cloned = false
            let transitioned = await performDocumentTransition {
                do {
                    switch editorCommandSession.captureActiveCommittedText() {
                    case let .captured(text):
                        guard let chapterID = selectedChapterID,
                              let episodeID = selectedEpisodeID else { return }
                        if document.episode(episodeID)?.episode.content != text {
                            document.updateEpisodeContent(text, for: episodeID, in: chapterID)
                            localEditGeneration &+= 1
                            saveCoordinator.markDirty()
                        }
                    case .compositionInProgress:
                        operationErrorMessage = "日本語入力を確定してから、アカウントへ追加してください。"
                        return
                    case .notActive:
                        break
                    }
                    guard await saveNow(),
                          await checkpointSnapshotSyncV2(document, reason: .explicit),
                          !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope else {
                        operationErrorMessage = "端末へ保存できないため、アカウントへの追加を中止しました。"
                        return
                    }
                    let clone = try await application.cloneWorkIntoActiveAccount(
                        sourceWorkID: sourceWorkID,
                        newWorkID: WorkID(UUID()),
                        newDocumentID: DocumentID(UUID())
                    )
                    guard !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope else { return }
                    let opened = try await application.openLocal(workID: clone.newWorkID)
                    guard !isSyncV2AccountTransitionActive,
                          currentDocumentSessionToken == expectedSession,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          opened.workID == clone.newWorkID,
                          let value = opened.document,
                          installSnapshotSyncV2Opened(opened, value: value) else { return }
                    let state = await application.uiState(workID: clone.newWorkID)
                    guard !isSyncV2AccountTransitionActive,
                          snapshotSyncV2AccountScope == expectedAccountScope,
                          syncV2ActiveWorkID == clone.newWorkID else { return }
                    applySnapshotSyncV2State(state)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        _ = await refreshLibrary()
                        await resumeSnapshotSyncV2()
                    }
                    cloned = true
                } catch {
                    operationErrorMessage = "作品をこのアカウントへ追加できませんでした。元の端末作品は保持しています。"
                }
            }
            return transitioned && cloned
        }
    }
}
