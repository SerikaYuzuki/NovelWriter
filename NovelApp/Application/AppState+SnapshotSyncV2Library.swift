import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

/// macOSのv2作品棚とremote catalogの投影。
extension AppState {
    private var permitsLibraryWorkOpening: Bool {
        guard !isDocumentTransitionInProgress,
              !isTerminationPending,
              interactiveAuthOperationCount == 0 else { return false }
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
        let projection: SyncV2LibraryProjection
        do {
            projection = try await application.library()
        } catch {
            guard matchesSnapshotSyncV2AccountScope(accountScope) else { return }
            snapshotSyncLibraryLocalFailure = syncV2FailureKind(error)
            logSyncV2PresentationFailure(error)
            // Keep the last verified shelf on read failure.
            if shouldPresentSelection {
                startupState = .documentSelection(.init(works: snapshotSyncLibraryWorks,
                                                        presentation: .localAndRemote, connection: connection))
            }
            return
        }
        guard matchesSnapshotSyncV2AccountScope(accountScope) else { return }
        snapshotSyncLibraryLocalFailure = nil
        let pendingDeletionIDs = await (try? application.pendingDeletionWorkIDs()) ?? []
        let deletedIDs = await (try? application.deletedWorkIDs()) ?? []
        guard matchesSnapshotSyncV2AccountScope(accountScope) else { return }
        snapshotSyncPendingDeletionWorkIDs = pendingDeletionIDs
        let parkedWorkIDs = Set(
            projection.items
                .filter { $0.accountState == .parkedDifferentAccount }
                .map(\.workID)
        )
        lastStartupLibraryConnection = connection
        snapshotSyncCurrentWorkAccountState = currentSnapshotSyncV2WorkID.flatMap { workID in
            projection.items.first(where: { $0.workID == workID })?.accountState
        }
        var worksByID = Dictionary(uniqueKeysWithValues: projection.items.compactMap { item -> (WorkID, StartupLibraryWork)? in
            guard item.accountState == .active || item.accountState == .unbound
                || item.accountState == .parkedDifferentAccount else { return nil }
            let availability: StartupLibraryWorkAvailability = if item.accountState == .parkedDifferentAccount {
                .parked
            } else {
                switch item.availability {
                case .localOnly: .local
                case .cached: .cached
                case .remoteOnly: .remoteOnly
                }
            }
            let withConflict = item.accountState != .parkedDifferentAccount &&
                item.remoteProgress == .needsChoice
            let remoteProgress: SyncV2RemoteProgress = if item.accountState == .parkedDifferentAccount {
                .parkedDifferentAccount
            } else {
                item.remoteProgress
            }
            let work = StartupLibraryWork(
                id: item.workID.rawValue,
                title: item.title,
                availability: withConflict ? .conflict : availability,
                workID: item.workID,
                remoteProgress: remoteProgress,
                oldestUnreceivedAt: item.oldestUnreceivedAt,
                accountState: item.accountState, remoteHeadConfirmed: item.remoteHeadConfirmed,
                localGeneration: item.localGeneration
            )
            return (item.workID, work)
        })
        for remote in snapshotSyncRemoteCatalogItems {
            if parkedWorkIDs.contains(remote.workID) || deletedIDs.contains(remote.workID) {
                continue
            }
            if let local = worksByID[remote.workID] {
                let availability: StartupLibraryWorkAvailability = local.availability == .conflict
                    ? .conflict
                    : (local.availability == .remoteOnly ? .remoteOnly : .cached)
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: local.availability == .remoteOnly || local.title.isEmpty ? remote.title : local.title,
                    availability: availability,
                    workID: remote.workID,
                    remoteProgress: local.remoteProgress,
                    oldestUnreceivedAt: local.oldestUnreceivedAt,
                    accountState: local.accountState, remoteHeadConfirmed: local.remoteHeadConfirmed,
                    localGeneration: local.localGeneration
                )
            } else {
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: remote.title,
                    availability: .remoteOnly,
                    workID: remote.workID,
                    remoteProgress: .idle, accountState: .active
                )
            }
        }
        let works = worksByID.values.sorted { SyncV2LibraryPresentation.precedes(title: $0.title, workID: $0.workID, otherTitle: $1.title, otherWorkID: $1.workID) }
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
        snapshotSyncLibraryIsLoading = true
        snapshotSyncLibraryFailure = nil
        defer {
            if snapshotSyncV2CatalogRefreshToken == operationToken {
                snapshotSyncV2CatalogRefreshToken = nil
                snapshotSyncLibraryIsLoading = false
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
            guard matchesSnapshotSyncV2AccountScope(accountScope),
                  snapshotSyncV2CatalogRefreshToken == operationToken else { return }
            if error as? SyncV2Failure == .authenticationRequired, case .signedIn = authUIState {
                authUIState = .failed("認証の有効期限が切れました。Appleで再サインインしてください。原稿はこの端末に保存されています。")
            }
            snapshotSyncLibraryFailure = syncV2FailureKind(error)
            logSyncV2PresentationFailure(error)
            // Offline catalog reads leave the verified local shelf intact.
        }
    }

    /// Workbench の「作品一覧」境界。表示中のEditorをIME確定し、dirtyなら
    /// SQLite checkpointだけを完了してから一覧へ戻る。remote workerは共有
    /// application側へ委譲し、この遷移では待たない。
    @discardableResult
    func returnToSnapshotLibrary() async -> Bool {
        guard snapshotSyncV2Application != nil,
              permitsDocumentTransitionOperation else { return false }
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
        if snapshotSyncV2RemoteOnlyOpeningWorkID == work.workID, let task = snapshotSyncV2RemoteOnlyOpenTask {
            return await task.value
        }
        let accountScope = snapshotSyncV2AccountScopeToken
        // Selecting another shelf item explicitly retires any older remote
        // download/adoption operation before its bytes can cross the gate.
        cancelSnapshotSyncV2BackgroundOperations()
        if work.availability == .remoteOnly {
            return await startRemoteOnlyOpen(work, using: application)
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsLibraryWorkOpening,
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
                guard matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
                snapshotSyncLibraryOpenFailure = syncV2FailureKind(error)
                logSyncV2PresentationFailure(error)
                operationMessage = remoteOnlyOpenErrorMessage(error)
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
    ) async -> Bool {
        guard snapshotSyncV2RemoteOnlyOpenTask == nil,
              containsSnapshotSyncV2LibraryWork(work) else { return false }
        let expectedSession = documentSessionToken
        let expectedWorkID = currentSnapshotSyncV2WorkID
        let expectedSnapshotSession = snapshotSyncV2Session
        let accountScope = snapshotSyncV2AccountScopeToken
        let operationToken = UUID()
        snapshotSyncV2RemoteOnlyOpenToken = operationToken
        snapshotSyncV2RemoteOnlyOpeningWorkID = work.workID
        snapshotSyncV2RemoteOnlyOpenStartedAt = Date()
        snapshotSyncLibraryOpenFailure = nil
        let task = Task { @MainActor [weak self] in
            defer {
                self?.finishRemoteOnlyOpen(operationToken: operationToken)
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
                guard opened.document != nil else { throw SyncV2ApplicationError.workNotFound }
                guard !Task.isCancelled,
                      let self,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
                libraryImportPhases[work.workID] = ImportPhase(stage: .opening)
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
                    guard await (try? application.isCurrentLocalVersion(opened)) == true else { return false }
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
                reportRemoteOnlyOpenResult(
                    installed: installed, validationRejected: validationRejected, work: work,
                    operationToken: operationToken, accountScope: accountScope, expectedSession: expectedSession
                )
                return installed
            } catch is CancellationError {
                return false
            } catch {
                guard let self,
                      snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                      matchesSnapshotSyncV2AccountScope(accountScope),
                      documentSessionToken == expectedSession,
                      containsSnapshotSyncV2LibraryWork(work) else { return false }
                reportRemoteOnlyOpenFailure(error)
                return false
            }
        }
        snapshotSyncV2RemoteOnlyOpenTask = task
        return await task.value
    }

    private func reportRemoteOnlyOpenFailure(_ error: Error) {
        snapshotSyncLibraryOpenFailure = syncV2FailureKind(error)
        logSyncV2PresentationFailure(error)
        operationMessage = remoteOnlyOpenErrorMessage(error)
        AccessibilityNotification.Announcement(operationMessage ?? "作品を取り込めませんでした").post()
    }

    private func finishRemoteOnlyOpen(operationToken: UUID) {
        if snapshotSyncV2RemoteOnlyOpenToken == operationToken {
            snapshotSyncV2RemoteOnlyOpenToken = nil
            snapshotSyncV2RemoteOnlyOpenTask = nil
            snapshotSyncV2RemoteOnlyOpeningWorkID = nil
            snapshotSyncV2RemoteOnlyOpenStartedAt = nil
        }
    }

    private func reportRemoteOnlyOpenResult(
        installed: Bool,
        validationRejected: Bool,
        work: StartupLibraryWork,
        operationToken: UUID,
        accountScope: SnapshotSyncV2AccountScopeToken,
        expectedSession: AppDocumentSessionToken
    ) {
        if !installed,
           !Task.isCancelled,
           snapshotSyncV2RemoteOnlyOpenToken == operationToken,
           matchesSnapshotSyncV2AccountScope(accountScope),
           documentSessionToken == expectedSession,
           containsSnapshotSyncV2LibraryWork(work),
           !validationRejected {
            operationMessage = "作品の取得が完了しました。作品一覧を更新してから開いてください。"
        }
        if validationRejected {
            let failure = SyncV2Failure.fatal(.invalidLocalState)
            snapshotSyncLibraryOpenFailure = failure
            logSyncV2PresentationFailure(failure)
            AccessibilityNotification.Announcement(remoteOnlyOpenErrorMessage(failure)).post()
        }
        if installed {
            AccessibilityNotification.Announcement("作品をこの端末に取り込みました").post()
        }
    }
}
