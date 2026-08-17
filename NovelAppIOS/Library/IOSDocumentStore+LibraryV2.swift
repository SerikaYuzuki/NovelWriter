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
    var workID: WorkID? { workingCopyID.workID }
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

    var usesSnapshotSyncRuntime: Bool {
        snapshotSyncV2Application != nil
    }

    var canExplicitlySyncCurrentWork: Bool {
        snapshotSyncV2Application != nil && startupState == .ready
    }

    var canPublishCurrentWorkToCloud: Bool {
        canExplicitlySyncCurrentWork
    }

    var isExplicitSyncInFlight: Bool {
        isSnapshotSyncInFlight
    }

    var activeCloudWorkID: WorkID? {
        guard startupState == .ready,
              syncV2ParkedAccountID == nil else { return nil }
        return syncV2ActiveWorkID
    }

    @discardableResult
    func refreshLibrary() async -> Bool {
        do {
            try await reloadLibraryItems()
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

    func reloadLibraryItems() async throws {
        guard let application = snapshotSyncV2Application else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        let projection = try await application.library()
        let localItems = exposesAccountScopedSyncV2Items
            ? projection.items
            : projection.items.filter { $0.accountState == .unbound }
        syncV2LibraryItems = mergeRemoteCatalog(
            into: localItems,
            catalog: exposesAccountScopedSyncV2Items ? syncV2RemoteCatalogItems : []
        )
        libraryItems = []
        verifiedPrivateDocumentIDs = []
    }

    /// Reads the account-scoped remote catalog page.  The runtime/provider is
    /// responsible for account fencing; this store only retains the opaque
    /// WorkID/title/head projection for the shelf.
    @discardableResult
    func refreshRemoteCatalog(reset: Bool = true) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        guard !syncV2RemoteCatalogIsLoading else { return false }
        if reset {
            syncV2RemoteCatalogCursor = nil
            syncV2RemoteCatalogItems = []
        }
        syncV2RemoteCatalogIsLoading = true
        syncV2RemoteCatalogError = nil
        defer { syncV2RemoteCatalogIsLoading = false }
        do {
            let page = try await application.refreshRemoteCatalog(
                cursor: syncV2RemoteCatalogCursor,
                pageSize: 100
            )
            var rows = Dictionary(
                uniqueKeysWithValues: syncV2RemoteCatalogItems.map { ($0.workID, $0) }
            )
            for item in page.items {
                rows[item.workID] = item
            }
            syncV2RemoteCatalogItems = rows.values.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            syncV2RemoteCatalogCursor = page.nextCursor
            try await reloadLibraryItems()
            return true
        } catch {
            syncV2RemoteCatalogError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func loadMoreRemoteCatalog() async -> Bool {
        guard syncV2RemoteCatalogCursor != nil else { return false }
        return await refreshRemoteCatalog(reset: false)
    }

    @discardableResult
    func refreshSnapshotHistory(for workID: WorkID, reset: Bool = true) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        if reset || syncV2HistoryWorkID != workID {
            syncV2HistoryItems = []
            syncV2HistoryCursor = nil
            syncV2HistoryWorkID = workID
            syncV2HistoryLocalAvailability = .unavailable
            syncV2HistoryOnlineAvailability = .unavailable
            syncV2HistoryOnlineFailure = nil
        }
        do {
            let page = try await application.historyPage(
                workID: workID,
                cursor: syncV2HistoryCursor,
                pageSize: 100
            )
            syncV2HistoryItems.append(contentsOf: page.items)
            syncV2HistoryCursor = page.nextCursor
            syncV2HistoryLocalAvailability = page.localAvailability
            syncV2HistoryOnlineAvailability = page.onlineAvailability
            syncV2HistoryOnlineFailure = page.onlineFailure
            return true
        } catch {
            syncV2HistoryOnlineFailure = (error as? SyncV2Failure) ?? .offline
            return false
        }
    }

    func mergeRemoteCatalog(
        into localItems: [SyncV2LibraryItem],
        catalog: [SyncV2RemoteCatalogEntry]
    ) -> [SyncV2LibraryItem] {
        var rows = Dictionary(uniqueKeysWithValues: localItems.map { ($0.workID, $0) })
        for remote in catalog {
            if let local = rows[remote.workID] {
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
        if snapshotSyncV2Application != nil, let workID = id.workID {
            return await openSnapshotSyncV2(workID: workID.rawValue)
        }
        return false
    }

    func openRemoteOnly(workID: WorkID) async -> Bool {
        let opened = await openSnapshotSyncV2(workID: workID.rawValue)
        if opened {
            try? await reloadLibraryItems()
        }
        return opened
    }

    /// Explicitly promotes an unbound local Work into the signed-in account.
    /// Sign-in alone never adopts or uploads that Work; this action creates a
    /// new WorkID, opens it under the same document gate, and leaves the
    /// original unbound Work intact.
    @discardableResult
    func cloneActiveWorkIntoSignedInAccount() async -> Bool {
        guard let application = snapshotSyncV2Application,
              let sourceWorkID = syncV2ActiveWorkID,
              syncV2ParkedAccountID == nil,
              case .signedIn = authUIState,
              !syncV2AccountCloneInFlight else { return false }
        syncV2AccountCloneInFlight = true
        defer { syncV2AccountCloneInFlight = false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            do {
                switch editorCommandSession.captureActiveCommittedText() {
                case let .captured(text):
                    guard let chapterID = selectedChapterID,
                          let episodeID = selectedEpisodeID else { return false }
                    updateEpisodeContent(text, chapterID: chapterID, episodeID: episodeID)
                case .compositionInProgress:
                    operationErrorMessage = "日本語入力を確定してから、アカウントへ追加してください。"
                    return false
                case .notActive:
                    break
                }
                guard await saveNow(),
                      await checkpointSnapshotSyncV2(document, reason: .explicit) else {
                    operationErrorMessage = "端末へ保存できないため、アカウントへの追加を中止しました。"
                    return false
                }
                let clone = try await application.cloneWorkIntoActiveAccount(
                    sourceWorkID: sourceWorkID,
                    newWorkID: WorkID(UUID()),
                    newDocumentID: DocumentID(UUID())
                )
                let opened = try await application.open(workID: clone.newWorkID)
                guard let value = opened.document else { return false }
                installSnapshotSyncV2Opened(opened, value: value)
                await applySnapshotSyncV2State(application.uiState(workID: clone.newWorkID))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await refreshLibrary()
                    await resumeSnapshotSyncV2()
                }
                return true
            } catch {
                operationErrorMessage = "作品をこのアカウントへ追加できませんでした。元の端末作品は保持しています。"
                return false
            }
        }
    }
}
