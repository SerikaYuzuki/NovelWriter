import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

/// macOSのv2作品棚とremote catalogの投影。
extension AppState {
    private var permitsLibraryWorkOpening: Bool {
        guard !isDocumentTransitionInProgress, !isTerminationPending else { return false }
        switch startupState {
        case .ready, .documentSelection:
            return true
        case .loading, .recovery:
            return false
        }
    }

    private func containsSnapshotSyncV2LibraryWork(_ work: StartupLibraryWork) -> Bool {
        snapshotSyncLibraryWorks.contains {
            $0.id == work.id && $0.workID == work.workID && $0.title == work.title
        }
    }

    func refreshSnapshotLibrary() async {
        guard let application = snapshotSyncV2Application else { return }
        let accountScope = snapshotSyncV2AccountScopeToken
        let shouldPresentSelection = !startupState.isReady
        let connection: StartupLibraryConnection = switch authUIState {
        case .signedIn: .available
        case .signedOut, .unavailable, .signingIn, .failed: .offline
        }
        guard let projection = try? await application.library() else {
            guard matchesSnapshotSyncV2AccountScope(accountScope) else { return }
            // A transient local read failure must not erase the last verified
            // shelf. The cached projection remains usable offline and is
            // refreshed on the next explicit/background read.
            if shouldPresentSelection {
                startupState = .documentSelection(
                    .init(
                        works: snapshotSyncLibraryWorks,
                        presentation: .localAndRemote,
                        connection: connection
                    )
                )
            }
            return
        }
        guard matchesSnapshotSyncV2AccountScope(accountScope) else { return }
        lastStartupLibraryConnection = connection
        snapshotSyncCurrentWorkAccountState = currentSnapshotSyncV2WorkID.flatMap { workID in
            projection.items.first(where: { $0.workID == workID })?.accountState
        }
        var worksByID = Dictionary(uniqueKeysWithValues: projection.items.compactMap { item -> (WorkID, StartupLibraryWork)? in
            guard item.accountState == .active || item.accountState == .unbound else { return nil }
            let availability: StartupLibraryWorkAvailability = switch item.availability {
            case .localOnly: .local
            case .cached: .cached
            case .remoteOnly: .remoteOnly
            }
            let withConflict = item.remoteProgress == .needsChoice
            let work = StartupLibraryWork(
                id: item.workID.rawValue,
                title: item.title,
                availability: withConflict ? .conflict : availability,
                workID: item.workID,
                remoteProgress: item.remoteProgress
            )
            return (item.workID, work)
        })
        for remote in snapshotSyncRemoteCatalogItems {
            if let local = worksByID[remote.workID] {
                let availability: StartupLibraryWorkAvailability = local.availability == .conflict
                    ? .conflict
                    : .cached
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: local.title.isEmpty ? remote.title : local.title,
                    availability: availability,
                    workID: remote.workID,
                    remoteProgress: local.remoteProgress
                )
            } else {
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: remote.title,
                    availability: .remoteOnly,
                    workID: remote.workID,
                    remoteProgress: .idle
                )
            }
        }
        let works = worksByID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        snapshotSyncLibraryWorks = works
        if shouldPresentSelection {
            startupState = .documentSelection(.init(works: works, presentation: .localAndRemote, connection: connection))
        }
    }

    /// Refresh the account-scoped remote catalog in the background. The
    /// provider performs account/fence filtering; this layer only deduplicates
    /// by WorkID and merges the result into the local shelf.
    func refreshSnapshotRemoteCatalog() async {
        guard let application = snapshotSyncV2Application,
              let session = authSession,
              authUIState == .signedIn(accountID: session.accountID) else { return }
        let accountScope = snapshotSyncV2AccountScopeToken
        let operationToken = UUID()
        snapshotSyncV2CatalogRefreshToken = operationToken
        defer {
            if snapshotSyncV2CatalogRefreshToken == operationToken {
                snapshotSyncV2CatalogRefreshToken = nil
            }
        }
        do {
            var cursor: String?
            var items: [SyncV2RemoteCatalogEntry] = []
            repeat {
                guard matchesSnapshotSyncV2AccountScope(accountScope),
                      snapshotSyncV2CatalogRefreshToken == operationToken else { return }
                #if FUMINIWA_TEST_COMPOSITION
                let page = if let snapshotSyncV2CatalogOverride {
                    try await snapshotSyncV2CatalogOverride(application, cursor, 100)
                } else {
                    try await application.refreshRemoteCatalog(cursor: cursor, pageSize: 100)
                }
                #else
                let page = try await application.refreshRemoteCatalog(cursor: cursor, pageSize: 100)
                #endif
                guard matchesSnapshotSyncV2AccountScope(accountScope),
                      snapshotSyncV2CatalogRefreshToken == operationToken else { return }
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
            guard matchesSnapshotSyncV2AccountScope(accountScope),
                  snapshotSyncV2CatalogRefreshToken == operationToken else {
                return
            }
            snapshotSyncRemoteCatalogItems = items.reduce(into: [:]) { result, item in
                result[item.workID] = item
            }.values.sorted {
                $0.workID.description < $1.workID.description
            }
            guard matchesSnapshotSyncV2AccountScope(accountScope),
                  snapshotSyncV2CatalogRefreshToken == operationToken else {
                return
            }
            await refreshSnapshotLibrary()
        } catch {
            // Offline catalog reads leave the verified local shelf intact.
        }
    }

    /// Workbench の「作品一覧」境界。表示中のEditorをIME確定し、dirtyなら
    /// SQLite checkpointだけを完了してから一覧へ戻る。remote workerは共有
    /// application側へ委譲し、この遷移では待たない。
    @discardableResult
    func returnToSnapshotLibrary() async -> Bool {
        guard snapshotSyncV2Application != nil,
              permitsDocumentChoice else { return false }
        let returned = await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }

            if saveState != .saved {
                guard await saveNow() else { return false }
            }
            startupState = .documentSelection(
                .init(
                    works: snapshotSyncLibraryWorks,
                    presentation: .localAndRemote,
                    connection: lastStartupLibraryConnection
                )
            )
            return true
        }
        guard returned else { return false }

        // Refresh the local shelf after the gate releases. The read is local
        // SQLite/catalog projection; it must not hold the editor transition or
        // make this public boundary await an HTTP worker.
        Task { @MainActor [weak self] in
            await self?.refreshSnapshotLibrary()
        }
        return true
    }

    @discardableResult
    func openLibraryWork(_ work: StartupLibraryWork) async -> Bool {
        guard let application = snapshotSyncV2Application,
              work.isOpenable,
              permitsLibraryWorkOpening else { return false }
        let accountScope = snapshotSyncV2AccountScopeToken
        // Selecting another shelf item explicitly retires any older remote
        // download/adoption operation before its bytes can cross the gate.
        cancelSnapshotSyncV2BackgroundOperations()
        if work.availability == .remoteOnly {
            return startRemoteOnlyOpen(work, using: application)
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  matchesSnapshotSyncV2AccountScope(accountScope),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            if saveState != .saved {
                guard await saveNow() else { return false }
            }
            do {
                guard matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
                #if FUMINIWA_TEST_COMPOSITION
                let opened = if let snapshotSyncV2OpenLocalOverride {
                    try await snapshotSyncV2OpenLocalOverride(application, work.workID)
                } else {
                    try await application.openLocal(workID: work.workID)
                }
                #else
                let opened = try await application.openLocal(workID: work.workID)
                #endif
                guard matchesSnapshotSyncV2AccountScope(accountScope),
                      let openedDocument = opened.document else { return false }
                let newSnapshotSession = await application.beginSession(workID: opened.workID)
                guard matchesSnapshotSyncV2AccountScope(accountScope),
                      installV2Document(
                          openedDocument,
                          workID: opened.workID,
                          createdAt: opened.documentCreatedAt,
                          attachments: opened.attachments,
                          resources: opened.resources,
                          expectedWorkID: work.workID
                      ) else {
                    operationMessage = "作品データを検証できませんでした。端末の版は変更していません。"
                    return false
                }
                snapshotSyncV2Session = newSnapshotSession
                startupState = .ready
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                return false
            }
        }
    }

    /// Remote-only catalog entries are not local documents yet. Downloading
    /// their graph is allowed to suspend on a disconnected network, so it must
    /// never occupy the document-operation gate or mark the current editor as
    /// transitioning. The second gate below is the only place where the
    /// downloaded bytes can become the active editor.
    private func startRemoteOnlyOpen(
        _ work: StartupLibraryWork,
        using application: SyncV2Application
    ) -> Bool {
        guard snapshotSyncV2RemoteOnlyOpenTask == nil,
              containsSnapshotSyncV2LibraryWork(work) else { return false }
        let expectedSession = documentSessionToken
        let expectedWorkID = currentSnapshotSyncV2WorkID
        let expectedSnapshotSession = snapshotSyncV2Session
        let accountScope = snapshotSyncV2AccountScopeToken
        let operationToken = UUID()
        snapshotSyncV2RemoteOnlyOpenToken = operationToken
        snapshotSyncV2RemoteOnlyOpenTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.snapshotSyncV2RemoteOnlyOpenToken == operationToken {
                    self.snapshotSyncV2RemoteOnlyOpenToken = nil
                    self.snapshotSyncV2RemoteOnlyOpenTask = nil
                }
            }
            do {
                #if FUMINIWA_TEST_COMPOSITION
                let opened = if let snapshotSyncV2OpenOverride = self?.snapshotSyncV2OpenOverride {
                    try await snapshotSyncV2OpenOverride(application, work.workID)
                } else {
                    try await application.open(workID: work.workID)
                }
                #else
                let opened = try await application.open(workID: work.workID)
                #endif
                guard !Task.isCancelled,
                      let self,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      matchesSnapshotSyncV2AccountScope(accountScope) else { return }
                var validationRejected = false
                let installed = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          matchesSnapshotSyncV2AccountScope(accountScope),
                          permitsLibraryWorkOpening,
                          documentSessionToken == expectedSession,
                          currentSnapshotSyncV2WorkID == expectedWorkID,
                          snapshotSyncV2Session == expectedSnapshotSession,
                          containsSnapshotSyncV2LibraryWork(work),
                          let openedDocument = opened.document,
                          editorCommandSession.prepareForDocumentTransition() else { return false }
                    defer { editorCommandSession.resumeAfterDocumentTransition() }
                    isDocumentTransitionInProgress = true
                    defer { isDocumentTransitionInProgress = false }
                    if expectedWorkID != nil {
                        guard await saveNow() else { return false }
                    }
                    guard !Task.isCancelled,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          matchesSnapshotSyncV2AccountScope(accountScope),
                          documentSessionToken == expectedSession,
                          currentSnapshotSyncV2WorkID == expectedWorkID,
                          snapshotSyncV2Session == expectedSnapshotSession else { return false }
                    let newSnapshotSession = await application.beginSession(workID: opened.workID)
                    guard !Task.isCancelled,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          matchesSnapshotSyncV2AccountScope(accountScope),
                          documentSessionToken == expectedSession,
                          currentSnapshotSyncV2WorkID == expectedWorkID,
                          snapshotSyncV2Session == expectedSnapshotSession else { return false }
                    guard installV2Document(
                        openedDocument,
                        workID: opened.workID,
                        createdAt: opened.documentCreatedAt,
                        attachments: opened.attachments,
                        resources: opened.resources,
                        expectedWorkID: work.workID
                    ) else {
                        validationRejected = true
                        operationMessage = "取得した作品データを検証できませんでした。現在の作品は変更していません。"
                        return false
                    }
                    snapshotSyncV2Session = newSnapshotSession
                    startupState = .ready
                    await refreshSnapshotSyncV2UIState()
                    return true
                }
                if !installed,
                   !Task.isCancelled,
                   snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                   matchesSnapshotSyncV2AccountScope(accountScope),
                   documentSessionToken == expectedSession,
                   containsSnapshotSyncV2LibraryWork(work),
                   !validationRejected {
                    operationMessage = "作品の取得が完了しました。作品一覧を更新してから開いてください。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      matchesSnapshotSyncV2AccountScope(accountScope),
                      documentSessionToken == expectedSession,
                      containsSnapshotSyncV2LibraryWork(work) else { return }
                operationMessage = "作品を取得できませんでした。接続が戻ると再試行できます。"
            }
        }
        return true
    }
}
