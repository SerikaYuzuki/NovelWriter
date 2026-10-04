import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
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

    private var shouldPresentRefreshedLibrary: Bool {
        switch startupState {
        case .documentSelection:
            true
        case .loading:
            hasCompletedBootstrap && bootstrapTask == nil
        case .ready, .recovery:
            false
        }
    }

    func refreshSnapshotLibrary() async {
        guard let application = snapshotSyncV2Application else { return }
        let accountScope = snapshotSyncV2AccountScopeToken
        let connection: StartupLibraryConnection = switch authUIState {
        case .signedIn: .available
        case .signedOut, .unavailable, .signingIn, .failed: .offline
        }
        let refresh: LibraryRefresh
        do {
            var operations = LibraryOperations(application: application)
            #if FUMINIWA_TEST_COMPOSITION
            if let snapshotSyncV2LibraryOverride {
                operations.library = { try await snapshotSyncV2LibraryOverride(application) }
            }
            #endif
            guard let result = try await LibraryCoordinator(operations: operations).refresh(
                account: accountScope, currentAccount: { snapshotSyncV2AccountScopeToken },
                isCurrent: { true }, tolerateDeletionReadFailure: true
            ) else { return }
            refresh = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, matchesSnapshotSyncV2AccountScope(accountScope) else { return }
            snapshotSyncLibraryLocalFailure = syncV2FailureKind(error)
            logSyncV2PresentationFailure(error)
            // Keep the last verified shelf on read failure.
            if shouldPresentRefreshedLibrary {
                startupState = .documentSelection(.init(works: snapshotSyncLibraryWorks,
                                                        presentation: .localAndRemote, connection: connection))
            }
            return
        }
        guard !Task.isCancelled, matchesSnapshotSyncV2AccountScope(accountScope) else { return }
        snapshotSyncLibraryLocalFailure = nil
        snapshotSyncPendingDeletionWorkIDs = refresh.pendingDeletionIDs
        lastStartupLibraryConnection = connection
        snapshotSyncCurrentWorkAccountState = currentSnapshotSyncV2WorkID.flatMap { workID in
            refresh.projection.items.first(where: { $0.workID == workID })?.accountState
        }
        let rows = refresh.merged(
            catalog: snapshotSyncRemoteCatalogItems,
            previousItems: snapshotSyncLibraryWorks.map(Self.snapshotLibraryItem), includesQuarantinedItems: false
        )
        let works = rows.compactMap(Self.startupLibraryWork).map { $0.1 }
        snapshotSyncLibraryWorks = works
        if shouldPresentRefreshedLibrary {
            startupState = .documentSelection(.init(works: works, presentation: .localAndRemote, connection: connection))
        }
    }

    static func startupLibraryWork(_ item: SyncV2LibraryItem) -> (WorkID, StartupLibraryWork)? {
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
            historyBackfillNote: item.historyBackfillNote,
            oldestUnreceivedAt: item.oldestUnreceivedAt,
            accountState: item.accountState, remoteHeadConfirmed: item.remoteHeadConfirmed,
            localGeneration: item.localGeneration
        )
        return (item.workID, work)
    }

    /// Adapts the previous macOS shelf for retention of pending deletion rows.
    static func snapshotLibraryItem(_ work: StartupLibraryWork) -> SyncV2LibraryItem {
        let availability: SyncV2LibraryAvailability = switch work.availability {
        case .remoteOnly: .remoteOnly
        case .cached, .conflict: .cached
        case .local, .pending, .parked, .excluded: .localOnly
        }
        return SyncV2LibraryItem(
            workID: work.workID, title: work.title, availability: availability,
            accountState: work.accountState, localGeneration: work.localGeneration,
            remoteHeadConfirmed: work.remoteHeadConfirmed, remoteProgress: work.remoteProgress,
            oldestUnreceivedAt: work.oldestUnreceivedAt, historyBackfillNote: work.historyBackfillNote
        )
    }

    /// Refresh the account-scoped remote catalog in the background. The
    /// provider performs account/fence filtering; this layer only deduplicates
    /// by WorkID and merges the result into the local shelf.
    func refreshSnapshotRemoteCatalog(loadMore: Bool = false) async {
        if loadMore, snapshotSyncLibraryIsLoading || snapshotSyncRemoteCatalogNextCursor == nil {
            return
        }
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
            var operations = LibraryOperations(application: application)
            #if FUMINIWA_TEST_COMPOSITION
            if let snapshotSyncV2CatalogOverride {
                operations.catalog = { try await snapshotSyncV2CatalogOverride(application, $0, $1) }
            }
            #endif
            guard let page = try await LibraryCoordinator(operations: operations).catalogPage(
                cursor: loadMore ? snapshotSyncRemoteCatalogNextCursor : nil,
                existingItems: loadMore ? snapshotSyncRemoteCatalogItems : [], order: .workID,
                account: accountScope, currentAccount: { snapshotSyncV2AccountScopeToken },
                isCurrent: { snapshotSyncV2CatalogRefreshToken == operationToken }
            ) else { return }
            snapshotSyncRemoteCatalogNextCursor = page.nextCursor
            snapshotSyncRemoteCatalogItems = page.items
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
              permitsDocumentDeparture else { return false }
        let expected = CheckpointCoordinator.context(of: self)
        let returned = await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentDeparture,
                  CheckpointCoordinator.matches(expected, host: self),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }

            guard await ConflictCoordinator.saveBeforeDeparture(
                currentWorkID: currentSnapshotSyncV2WorkID, pendingDuplicateID: syncV2KeepBothPendingWorkID,
                save: {
                    if self.saveState == .saved {
                        return true
                    }
                    return await self.saveNow()
                }
            ), CheckpointCoordinator.matches(expected, host: self) else { return false }
            retireFrozenKeepBothWorkForLibrary()
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

    func workspaceWorkOpenCoordinator(_ application: SyncV2Application) -> WorkOpenCoordinator {
        var coordinator = WorkOpenCoordinator(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        if let snapshotSyncV2OpenLocalOverride {
            coordinator.openLocal = { try await snapshotSyncV2OpenLocalOverride(application, $0) }
        }
        if let snapshotSyncV2OpenOverride {
            coordinator.download = { try await snapshotSyncV2OpenOverride(application, $0) }
        }
        #endif
        return coordinator
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
        let expected = CheckpointCoordinator.context(of: self)
        snapshotSyncLibraryOpenFailure = nil
        operationMessage = nil
        // Selecting another shelf item explicitly retires any older remote
        // download/adoption operation before its bytes can cross the gate.
        cancelSnapshotSyncV2BackgroundOperations()
        if work.availability == .remoteOnly {
            return await startRemoteOnlyOpen(work, using: application)
        }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsLibraryWorkOpening,
                  CheckpointCoordinator.matches(expected, host: self),
                  matchesSnapshotSyncV2AccountScope(accountScope),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard await ConflictCoordinator.saveBeforeDeparture(
                currentWorkID: currentSnapshotSyncV2WorkID, pendingDuplicateID: syncV2KeepBothPendingWorkID,
                save: {
                    if self.saveState == .saved {
                        return true
                    }
                    return await self.saveNow()
                }
            ) else { return false }
            do {
                let prepared = operationContext
                let coordinator = workspaceWorkOpenCoordinator(application)
                guard let opened = try await coordinator.readLocal(workID: work.workID, isCurrent: {
                    prepared.isCurrent(self.operationContext) && self.matchesSnapshotSyncV2AccountScope(accountScope)
                }) else { return false }
                let installed = try await coordinator.installAtPreparedBoundary(
                    opened, workID: work.workID, host: self, createsSession: true,
                    isCurrent: { self.matchesSnapshotSyncV2AccountScope(accountScope) },
                    install: { opened, session in
                        guard let value = opened.document,
                              self.installV2Document(value, workID: opened.workID, createdAt: opened.documentCreatedAt,
                                                     attachments: opened.attachments, resources: opened.resources,
                                                     expectedWorkID: work.workID) else {
                            self.snapshotSyncLibraryOpenFailure = .fatal(.invalidLocalState)
                            self.operationMessage = "作品データを検証できませんでした。端末の版は変更していません。"
                            return false
                        }
                        self.snapshotSyncV2Session = session
                        self.startupState = .ready
                        return true
                    }, project: { self.applySnapshotSyncV2State($0) }
                )
                if installed {
                    scheduleAutomaticServerAdoption(expectedAccountScope: accountScope)
                }
                return installed
            } catch {
                guard matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
                reportSnapshotSyncV2OpenFailure(error)
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
        let operation = WorkspaceOperationContext(workID: expectedWorkID, session: expectedSession,
                                                  account: accountScope, editGeneration: nil)
        let operationToken = syncSessionController.beginRemoteOnlyOpen(workID: work.workID)
        snapshotSyncLibraryOpenFailure = nil
        let task = Task { @MainActor [weak self] in
            defer {
                self?.finishRemoteOnlyOpen(operationToken: operationToken)
            }
            do {
                guard let self else { return false }
                let coordinator = workspaceWorkOpenCoordinator(application)
                guard let opened = try await coordinator.downloadRemoteOnly(
                    workID: work.workID,
                    isCurrent: { self.snapshotSyncV2RemoteOnlyOpenToken == operationToken
                        && self.matchesSnapshotSyncV2AccountScope(accountScope)
                    },
                    opening: { self.libraryImportPhases[work.workID] = ImportPhase(stage: .opening) }
                ) else { return false }
                var validationRejected = false
                let installed = await documentOperationGate.perform { [weak self] in
                    guard let self,
                          snapshotSyncV2RemoteOnlyOpenToken == operationToken,
                          matchesSyncOperation(operation),
                          permitsLibraryWorkOpening,
                          snapshotSyncV2Session == expectedSnapshotSession,
                          containsSnapshotSyncV2LibraryWork(work),
                          let openedDocument = opened.document,
                          editorCommandSession.prepareForDocumentTransition() else { return false }
                    defer { editorCommandSession.resumeAfterDocumentTransition() }
                    isDocumentTransitionInProgress = true
                    defer { isDocumentTransitionInProgress = false }
                    if expectedWorkID != nil {
                        guard await ConflictCoordinator.saveBeforeDeparture(
                            currentWorkID: currentSnapshotSyncV2WorkID, pendingDuplicateID: syncV2KeepBothPendingWorkID,
                            save: { await self.saveNow() }
                        ) else { return false }
                    }
                    return await (try? coordinator.installAtPreparedBoundary(
                        opened, workID: work.workID, host: self, verifiesLocalVersion: true, createsSession: true,
                        isCurrent: { self.snapshotSyncV2RemoteOnlyOpenToken == operationToken
                            && self.matchesSyncOperation(operation)
                            && self.snapshotSyncV2Session == expectedSnapshotSession
                        },
                        install: { opened, session in
                            guard self.installV2Document(
                                openedDocument, workID: opened.workID, createdAt: opened.documentCreatedAt,
                                attachments: opened.attachments, resources: opened.resources, expectedWorkID: work.workID
                            ) else {
                                validationRejected = true
                                self.operationMessage = "取得した作品データを検証できませんでした。現在の作品は変更していません。"
                                return false
                            }
                            self.snapshotSyncV2Session = session
                            self.startupState = .ready
                            return true
                        }, project: { self.applySnapshotSyncV2State($0) }
                    )) == true
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
        reportSnapshotSyncV2OpenFailure(error)
        AccessibilityNotification.Announcement(operationMessage ?? "作品を取り込めませんでした").post()
    }

    private func finishRemoteOnlyOpen(operationToken: UUID) {
        syncSessionController.finishRemoteOnlyOpen(owner: operationToken)
    }

    private func reportRemoteOnlyOpenResult(
        installed: Bool,
        validationRejected: Bool,
        work: StartupLibraryWork,
        operationToken: UUID,
        accountScope: WorkspaceAccountScope,
        expectedSession: WorkspaceSessionToken
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
