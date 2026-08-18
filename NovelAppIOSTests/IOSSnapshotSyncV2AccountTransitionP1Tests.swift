import Foundation
@testable import FUMINIWAIOS
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store
import Testing

@MainActor
struct IOSSnapshotSyncV2P1TransitionTests {
    @Test("parked local Work wins over a same-ID remote catalog row")
    func parkedCatalogCollisionKeepsLocalOnlyRow() throws {
        let workID = WorkID(UUID())
        let parked = SyncV2LibraryItem(
            workID: workID,
            title: "端末に保留した作品",
            availability: .localOnly,
            accountState: .parkedDifferentAccount,
            localGeneration: 3
        )
        let defaultsSuiteName = "FUMINIWA.iOS.parked-collision.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-parked-collision-\(UUID())")
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        let store = IOSDocumentStore(
            userDefaults: defaults,
            libraryRoot: root
        )

        let rows = store.mergeRemoteCatalog(
            into: [parked],
            catalog: [SyncV2RemoteCatalogEntry(workID: workID, title: "別アカウントの同ID", head: nil)]
        )
        #expect(rows.count == 1)
        #expect(rows.first?.title == "端末に保留した作品")
        #expect(rows.first?.availability == .localOnly)
        #expect(rows.first?.accountState == .parkedDifferentAccount)
    }

    @Test("旧protocol epochはsigned-inに昇格せずparked local-onlyを保持する")
    func unsupportedAuthEpochFailsClosed() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        store.authSession = nil
        store.authUIState = .signedOut

        let unsupported = makeIOSAuthSession(
            accountID: "old-account",
            fence: "old-fence",
            protocolEpoch: 1
        )
        #expect(await store.transitionFuminiwaSession(
            to: unsupported,
            authState: .signedIn(accountID: unsupported.accountID)
        ) == false)
        #expect(store.authSession == nil)
        if case .failed = store.authUIState {} else {
            Issue.record("unsupported session was not surfaced as a typed auth failure")
        }
        #expect(store.syncV2LibraryItems.map(\.workID) == [workID])
        #expect(store.syncV2LibraryItems.first?.accountState == .parkedDifferentAccount)
        #expect(store.syncV2LibraryItems.first?.availability == .localOnly)
    }

    @Test("parked laneはsame accountで復帰し、別accountではlocal-onlyに留まる")
    func parkedLaneAccountTransitionPolicy() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        store.updateDocumentTitle("端末で編集した作品")
        #expect(await store.saveNow())
        let application = try #require(store.snapshotSyncV2Application)
        let oldBinding = SyncV2AccountScopeBinding(
            accountID: "test-account",
            accountFence: "test-fence",
            serverInstanceID: "test-server",
            protocolEpoch: 2
        )

        try await transitionApplicationScopes(
            application,
            from: nil,
            to: nil
        )
        let parked = try await application.library().items.first { $0.workID == workID }
        #expect(parked?.accountState == .parkedDifferentAccount)
        #expect(parked?.availability == .localOnly)

        try await transitionApplicationScopes(
            application,
            from: nil,
            to: oldBinding
        )
        let restored = try await application.library().items.first { $0.workID == workID }
        #expect(restored?.accountState == .active)

        try await transitionApplicationScopes(
            application,
            from: oldBinding,
            to: oldBinding
        )
        #expect(try await application.library().items.first { $0.workID == workID }?.accountState == .active)

        try await transitionApplicationScopes(
            application,
            from: oldBinding,
            to: nil
        )
        let configuration = try #require(
            IOSDocumentStore.testRuntimeConfigurations[environment.root.standardizedFileURL]
        )
        await configuration.vault.replaceAccount(
            TestAccount(accountID: "other-account", accountFence: "other-fence")
        )
        let otherBinding = SyncV2AccountScopeBinding(
            accountID: "other-account",
            accountFence: "other-fence",
            serverInstanceID: "test-server",
            protocolEpoch: 2
        )
        try await transitionApplicationScopes(
            application,
            from: nil,
            to: otherBinding
        )
        let isolated = try await application.library().items.first { $0.workID == workID }
        #expect(isolated?.accountState == .parkedDifferentAccount)
        #expect(isolated?.availability == .localOnly)
    }

    private func transitionApplicationScopes(
        _ application: SyncV2Application,
        from old: SyncV2AccountScopeBinding?,
        to new: SyncV2AccountScopeBinding?
    ) async throws {
        let token = await application.beginAccountTransitionRemoteSuspension()
        do {
            try await application.transitionAccountScopes(
                from: old,
                to: new,
                suspensionToken: token
            )
        } catch {
            _ = await application.endAccountTransitionRemoteSuspension(
                token,
                resume: false
            )
            throw error
        }
        _ = await application.endAccountTransitionRemoteSuspension(
            token,
            resume: false
        )
    }

    @Test("server namespaceまたはepoch変更はSQLiteの旧laneをparkする")
    func serverNamespaceTransitionParksOldLane() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        let configuration = try #require(
            IOSDocumentStore.testRuntimeConfigurations[environment.root.standardizedFileURL]
        )
        let oldBinding = SyncV2AccountScopeBinding(
            accountID: "test-account",
            accountFence: "test-fence",
            serverInstanceID: UUID().uuidString.lowercased(),
            protocolEpoch: 2
        )
        let replacementBinding = SyncV2AccountScopeBinding(
            accountID: "test-account",
            accountFence: "test-fence",
            serverInstanceID: UUID().uuidString.lowercased(),
            protocolEpoch: 2
        )

        // The test runtime normally seeds the fixed test-server binding. Move
        // that durable row to the old session's namespace, then exercise the
        // app-host transition adapter itself (rather than calling the actor
        // API directly). This keeps the regression SQLite-backed while the
        // production adapter still compares all four binding values.
        let sqlite = try LocalSyncV2Store(
            root: configuration.localRoot.url,
            policy: .openExisting
        )
        try await sqlite.rebindWork(
            workID: workID,
            from: V2AccountBinding(
                accountID: "test-account",
                accountFence: "test-fence",
                serverInstanceID: "test-server",
                protocolEpoch: 2
            ),
            to: V2AccountBinding(
                accountID: oldBinding.accountID,
                accountFence: oldBinding.accountFence,
                serverInstanceID: oldBinding.serverInstanceID,
                protocolEpoch: oldBinding.protocolEpoch
            )
        )
        await sqlite.close()

        let oldServerUUID = try #require(UUID(uuidString: oldBinding.serverInstanceID))
        store.authSession = makeIOSAuthSession(
            accountID: oldBinding.accountID,
            fence: oldBinding.accountFence,
            protocolEpoch: 2,
            serverInstanceID: oldServerUUID
        )
        store.authUIState = .signedIn(accountID: oldBinding.accountID)
        let replacementServerUUID = try #require(UUID(uuidString: replacementBinding.serverInstanceID))
        let replacementSession = makeIOSAuthSession(
            accountID: replacementBinding.accountID,
            fence: replacementBinding.accountFence,
            protocolEpoch: 2,
            serverInstanceID: replacementServerUUID
        )
        #expect(await store.transitionFuminiwaSession(
            to: replacementSession,
            authState: .signedIn(accountID: replacementSession.accountID)
        ))

        let application = try #require(store.snapshotSyncV2Application)
        let parked = try await application.library().items.first { $0.workID == workID }
        #expect(parked?.accountState == .parkedDifferentAccount)
        #expect(parked?.availability == .localOnly)
    }

    @Test("server namespaceとprotocol epoch変更は旧conflict選択をstaleとして拒否する")
    func serverNamespaceAndEpochInvalidateConflictSelection() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        let oldServer = UUID()
        store.authSession = makeIOSAuthSession(
            accountID: "same-account",
            fence: "same-fence",
            protocolEpoch: 2,
            serverInstanceID: oldServer
        )
        store.authUIState = .signedIn(accountID: "same-account")
        let application = try #require(store.snapshotSyncV2Application)
        let state = try #require(await application.uiState(workID: workID))
        let conflict = SyncV2ConflictProjection(
            conflictID: UUID(),
            revision: 1,
            baseSnapshotID: nil,
            localSnapshotID: SnapshotID(data: Data("local".utf8)),
            remoteSnapshotID: SnapshotID(data: Data("remote".utf8)),
            sourceGeneration: 1
        )
        store.snapshotSyncState = SyncUIState(
            workID: workID,
            localDurability: state.localDurability,
            remoteProgress: .needsChoice,
            conflict: conflict,
            lastTypedResult: .conflictPending
        )
        store.snapshotSyncConflict = conflict
        let displayed = try #require(store.snapshotSyncV2DisplayedConflictSelection)

        let newServer = UUID()
        store.authSession = makeIOSAuthSession(
            accountID: "same-account",
            fence: "same-fence",
            protocolEpoch: 2,
            serverInstanceID: newServer
        )
        #expect(store.snapshotSyncV2AccountScope.serverInstanceID != oldServer.uuidString.lowercased())
        #expect(store.snapshotSyncV2AccountScope.protocolEpoch == 2)
        #expect(await store.resolveSnapshotSyncV2Conflict(
            using: .useServer,
            expectedSelection: displayed
        ) == false)

        store.authSession = makeIOSAuthSession(
            accountID: "same-account",
            fence: "same-fence",
            protocolEpoch: 2,
            serverInstanceID: oldServer
        )
        let staleEpochSelection = IOSSnapshotSyncV2ConflictSelection(
            workID: displayed.workID,
            session: displayed.session,
            editGeneration: displayed.editGeneration,
            accountScope: IOSSnapshotSyncV2AccountScope(
                accountID: "same-account",
                accountFence: "same-fence",
                serverInstanceID: oldServer.uuidString.lowercased(),
                protocolEpoch: 3
            ),
            conflict: displayed.conflict
        )
        #expect(await store.resolveSnapshotSyncV2Conflict(
            using: .useServer,
            expectedSelection: staleEpochSelection
        ) == false)
    }
}

@MainActor
struct IOSSnapshotSyncV2AccountRequestP1Tests {
    @Test("Apple交換待ちのrequest windowは旧remote workを止めlocal editだけ許可する")
    // The scenario intentionally keeps the request window open while it
    // exercises every remote entry point and the local checkpoint boundary.
    // swiftlint:disable:next function_body_length
    func appleExchangeRequestBlocksRemoteStarts() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        let application = try #require(store.snapshotSyncV2Application)
        let configuration = try #require(
            IOSDocumentStore.testRuntimeConfigurations[environment.root.standardizedFileURL]
        )
        try await waitForIOSP1OfflineWorker(
            application,
            remote: configuration.remote,
            workID: workID
        )
        let remoteOperationCount = await configuration.remote.recordedOperations().count

        let remoteOnlyWorkID = WorkID(UUID())
        let oldServer = UUID()
        let oldSession = makeIOSAuthSession(
            accountID: "test-account",
            fence: "test-fence",
            protocolEpoch: 2,
            serverInstanceID: oldServer
        )
        let replacementSession = makeIOSAuthSession(
            accountID: "test-account",
            fence: "test-fence",
            protocolEpoch: 2,
            serverInstanceID: UUID()
        )
        store.testServerInstanceIDOverride = "test-server"
        store.authSession = oldSession
        store.authUIState = .signedIn(accountID: "test-account")
        store.syncV2LibraryItems = [
            SyncV2LibraryItem(
                workID: workID,
                title: store.document.title,
                availability: .cached,
                accountState: .active
            ),
            SyncV2LibraryItem(
                workID: remoteOnlyWorkID,
                title: "交換中に取得してはいけない作品",
                availability: .remoteOnly,
                accountState: .active
            )
        ]
        let oldWorker: Task<Void, Never> = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
        }
        store.snapshotSyncV2ReprojectionTask = oldWorker
        store.snapshotSyncV2ReprojectionToken = UUID()

        let oldBinding = V2AccountBinding(
            accountID: oldSession.accountID,
            accountFence: oldSession.accountFence,
            serverInstanceID: "test-server",
            protocolEpoch: 2
        )
        let sqliteBefore = try LocalSyncV2Store(
            root: configuration.localRoot.url,
            policy: .openExisting
        )
        let oldPendingCount = try await sqliteBefore.pendingIntents(
            scope: .bound(oldBinding),
            workID: workID
        ).count
        let oldCommandCount = try await sqliteBefore.allSealedCommands(
            scope: .bound(oldBinding),
            workID: workID
        ).count
        await sqliteBefore.close()

        let preflightTitle = "Apple開始前にSQLiteへ確定するdirty本文"
        let localGenerationBeforeSignIn = store.localEditGeneration
        store.updateDocumentTitle(preflightTitle)
        #expect(store.saveState == .dirty)
        #expect(store.localEditGeneration == localGenerationBeforeSignIn + 1)

        let exchangeStarted = AsyncStream<Void>.makeStream()
        let exchangeRelease = AsyncStream<Void>.makeStream()
        store.testAppleSignInHandler = {
            exchangeStarted.continuation.yield(())
            for await _ in exchangeRelease.stream {
                break
            }
            return replacementSession
        }
        let signInTask = Task { @MainActor in
            await store.signInWithApple()
        }
        let exchangeDidStart = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exchangeStarted.stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard exchangeDidStart else {
            signInTask.cancel()
            exchangeRelease.continuation.finish()
            await signInTask.value
            Issue.record("Apple exchange did not enter the bounded request window")
            return
        }

        // The production sign-in entry point, not a manually toggled flag,
        // has already cancelled/invalidate()d the old UI task and durably
        // parked the old binding before the exchange suspension.
        #expect(oldWorker.isCancelled)
        #expect(store.snapshotSyncV2ReprojectionTask == nil)
        #expect(store.snapshotSyncV2ReprojectionToken == nil)
        #expect(store.authSession == nil)
        #expect(store.syncV2AccountTransitionRequestOwner != nil)
        #expect(store.syncV2RemoteSuspensionToken != nil)
        let parked = try await application.library().items.first { $0.workID == workID }
        #expect(parked?.accountState == .parkedDifferentAccount)
        #expect(parked?.availability == .localOnly)
        #expect(store.localEditGeneration == localGenerationBeforeSignIn + 1)

        // The request window fences remote work, but it must not freeze the
        // local shelf/editor while Apple UI or an exchange transport waits.
        #expect(await store.openSnapshotSyncV2(workID: workID.rawValue))
        #expect(await store.makeNewDocument())
        #expect(await store.openPrivateDocument(id: IOSPrivateDocumentID(workID: workID)))
        #expect(await store.refreshLibrary())
        let reloadedDuringTransition = try? await store.reloadLibraryItems()
        #expect(reloadedDuringTransition == true)
        await store.requestExport()
        let exportedDuringExchange = try #require(store.pendingExportURL)
        #expect(await store.importPackage(from: exportedDuringExchange))
        let importedWorkID = try #require(store.syncV2ActiveWorkID)
        let importedTitle = store.document.title
        store.dismissExport()

        // Exercise local history/restore on the parked source, then return to
        // the imported Work. Both are local-only operations and must not make
        // the late Apple response the owner of the editor surface.
        #expect(await store.openSnapshotSyncV2(workID: workID.rawValue))
        let parkedSnapshot = try LocalSyncV2Store(
            root: configuration.localRoot.url,
            policy: .openExisting
        )
        let parkedOpen = try await parkedSnapshot.open(
            workID: workID,
            scope: .parked
        )
        await parkedSnapshot.close()
        #expect(parkedOpen.summary.localGeneration >= 2)
        #expect(parkedOpen.document?.title == preflightTitle)

        #expect(await store.refreshSnapshotHistory(for: workID))
        if let localSnapshot = store.syncV2HistoryItems.first {
            #expect(await store.restoreSnapshotSyncV2(snapshotID: localSnapshot.snapshotID.rawValue))
        }
        #expect(await store.openSnapshotSyncV2(workID: importedWorkID.rawValue))
        #expect(store.syncV2ActiveWorkID == importedWorkID)
        #expect(store.document.title == importedTitle)
        let activeSessionBeforeExchange = try #require(store.currentDocumentSessionToken)

        await store.resumeSnapshotSyncV2()
        #expect(await store.synchronizeSnapshotSyncV2() == false)
        #expect(await store.refreshRemoteCatalog() == false)
        #expect(await store.adoptPendingSnapshotSyncV2() == false)
        #expect(await store.startRemoteOnlySnapshotSyncV2Open(workID: remoteOnlyWorkID) == false)
        #expect(await configuration.remote.recordedOperations().count == remoteOperationCount)

        let localGenerationBeforeEdit = store.localEditGeneration
        store.updateDocumentTitle("Apple交換待ちでも保持するローカル編集")
        #expect(store.document.title == "Apple交換待ちでも保持するローカル編集")
        #expect(store.localEditGeneration > localGenerationBeforeEdit)
        #expect(await store.saveNow())
        let activeTitleBeforeExchangeRelease = store.document.title
        let activeSessionAfterLocalEdit = try #require(store.currentDocumentSessionToken)
        #expect(await configuration.remote.recordedOperations().count == remoteOperationCount)

        let sqliteDuringExchange = try LocalSyncV2Store(
            root: configuration.localRoot.url,
            policy: .openExisting
        )
        let oldPendingDuringExchange = try await sqliteDuringExchange.pendingIntents(
            scope: .bound(oldBinding),
            workID: workID
        ).count
        let oldCommandsDuringExchange = try await sqliteDuringExchange.allSealedCommands(
            scope: .bound(oldBinding),
            workID: workID
        ).count
        await sqliteDuringExchange.close()
        #expect(oldPendingCount > 0)
        #expect(oldPendingDuringExchange == 0)
        #expect(oldCommandsDuringExchange == oldCommandCount)

        exchangeRelease.continuation.yield(())
        exchangeRelease.continuation.finish()
        await signInTask.value
        #expect(store.authSession?.accountID == replacementSession.accountID)
        #expect(store.syncV2AccountTransitionRequested == false)
        #expect(store.syncV2AccountTransitionRequestOwner == nil)
        #expect(store.syncV2RemoteSuspensionToken == nil)
        #expect(store.syncV2ActiveWorkID == importedWorkID)
        #expect(store.document.title == activeTitleBeforeExchangeRelease)
        #expect(store.currentDocumentSessionToken == activeSessionAfterLocalEdit)
        #expect(activeSessionAfterLocalEdit == activeSessionBeforeExchange)
        let rebound = try await application.library().items.first { $0.workID == workID }
        #expect(rebound?.accountState == .active)
        let imported = try await application.library().items.first { $0.workID == importedWorkID }
        #expect(imported?.accountState == .active)
        #expect(imported?.availability == .localOnly)
        try await waitForIOSP1RemoteOperation(
            configuration.remote,
            atLeast: remoteOperationCount + 1
        )
    }

    @Test("Apple交換キャンセル後はrequest windowを解放し、保存と再オープンを再開する")
    func appleExchangeCancellationReleasesRequestWindow() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)

        let title = "Apple交換キャンセル後も保持される本文"
        store.updateDocumentTitle(title)
        #expect(store.saveState == .dirty)
        store.testAppleSignInHandler = {
            throw CancellationError()
        }

        await store.signInWithApple()

        #expect(store.syncV2AccountTransitionRequested == false)
        #expect(store.syncV2AccountTransitionRequestOwner == nil)
        #expect(store.syncV2RemoteSuspensionToken == nil)
        #expect(store.authSession == nil)
        #expect(store.document.title == title)
        #expect(await store.saveNow())
        #expect(await store.openSnapshotSyncV2(workID: workID.rawValue))
        #expect(store.document.title == title)
    }

    @Test("キャンセルされたApple開始のstale leaseは再試行を塞がない")
    func staleAppleTransitionLeaseDoesNotBlockRetry() async {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        #if FUMINIWA_TEST_COMPOSITION
        store.testServerInstanceIDOverride = "test-server"
        #endif

        let replacementSession = makeIOSAuthSession(
            accountID: "retry-account",
            fence: "retry-fence",
            protocolEpoch: 2
        )
        store.testAppleSignInHandler = { replacementSession }
        store.authUIState = .failed("Appleでのサインインを完了できませんでした")
        store.syncV2AccountTransitionRequested = true
        store.syncV2AccountTransitionRequestOwner = UUID()

        await store.signInWithApple()

        #expect(store.authSession?.accountID == replacementSession.accountID)
        #expect(store.authUIState == .signedIn(accountID: replacementSession.accountID))
        #expect(store.syncV2AccountTransitionRequested == false)
        #expect(store.syncV2AccountTransitionRequestOwner == nil)
        #expect(store.syncV2RemoteSuspensionToken == nil)
    }

    @Test("iOS account transition lease is nested-owner and stale-release safe")
    func remoteSuspensionLeaseRejectsStaleRelease() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let workID = try #require(store.syncV2ActiveWorkID)
        let application = try #require(store.snapshotSyncV2Application)
        let configuration = try #require(
            IOSDocumentStore.testRuntimeConfigurations[environment.root.standardizedFileURL]
        )
        let first = await application.beginAccountTransitionRemoteSuspension()
        let second = await application.beginAccountTransitionRemoteSuspension()
        #expect(first != second)

        _ = try await application.checkpoint(
            workID: workID,
            document: store.document,
            reason: .autosave,
            documentCreatedAt: store.documentCreatedAt
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await configuration.remote.recordedOperations().isEmpty)

        #expect(await application.endAccountTransitionRemoteSuspension(first, resume: true))
        #expect(await application.endAccountTransitionRemoteSuspension(first, resume: true) == false)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await configuration.remote.recordedOperations().isEmpty)

        #expect(await application.endAccountTransitionRemoteSuspension(second, resume: false))
        try await application.resumePending()
        try await waitForIOSP1RemoteOperation(
            configuration.remote,
            expectedCount: 1
        )
    }

    @Test("parked shelf survives an iOS process/reopen boundary")
    func parkedShelfSurvivesProcessReopen() async throws {
        let environment = makeIOSP1Environment()
        defer { environment.cleanup() }
        let workID: WorkID
        let title = "再起動後も残る保留作品"
        do {
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            #expect(await store.configureSnapshotSyncV2())
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            workID = try #require(store.syncV2ActiveWorkID)
            store.updateDocumentTitle(title)
            #expect(await store.saveNow())
            let oldSession = makeIOSAuthSession(
                accountID: "test-account",
                fence: "test-fence",
                protocolEpoch: 2
            )
            #if FUMINIWA_TEST_COMPOSITION
            store.testServerInstanceIDOverride = "test-server"
            #endif
            store.authSession = oldSession
            store.authUIState = .signedIn(accountID: oldSession.accountID)
            #expect(await store.transitionFuminiwaSession(
                to: nil,
                authState: .signedOut
            ))
            #expect(store.syncV2LibraryItems.first(where: { $0.workID == workID })?.accountState
                == .parkedDifferentAccount)
        }
        await environment.releaseApplication()

        let reopened = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopened.bootstrap()
        #expect(reopened.syncV2LibraryItems.contains {
            $0.workID == workID && $0.accountState == .parkedDifferentAccount
        })
        #expect(await reopened.openSnapshotSyncV2(workID: workID.rawValue))
        #expect(reopened.document.title == title)
        #expect(reopened.isCurrentWorkParked)
        #expect(reopened.canExplicitlySyncCurrentWork == false)
    }
}

@MainActor
private func makeIOSP1Environment() -> TestEnvironment {
    let id = UUID().uuidString
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FUMINIWA-iOS-v2-account-transition-\(id)", isDirectory: true)
    let suiteName = "dev.serikayuzuki.fuminiwa.ios.v2.account-transition.\(id)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return TestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
}

private func waitForIOSP1OfflineWorker(
    _ application: SyncV2Application,
    remote: FakeSyncV2RemoteClient,
    workID: WorkID
) async throws {
    var previousOperationCount: Int?
    var stableSamples = 0
    for _ in 0 ..< 100 {
        let operationCount = await remote.recordedOperations().count
        if let state = await application.uiState(workID: workID),
           case .offline = state.remoteProgress {
            if previousOperationCount == operationCount {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            if stableSamples >= 3 {
                return
            }
        } else {
            stableSamples = 0
        }
        previousOperationCount = operationCount
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("test worker did not reach the offline terminal state")
}

private func waitForIOSP1RemoteOperation(
    _ remote: FakeSyncV2RemoteClient,
    expectedCount: Int
) async throws {
    try await waitForIOSP1RemoteOperation(remote, atLeast: expectedCount)
}

private func waitForIOSP1RemoteOperation(
    _ remote: FakeSyncV2RemoteClient,
    atLeast expectedCount: Int
) async throws {
    for _ in 0 ..< 100 {
        if await remote.recordedOperations().count >= expectedCount {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("test remote operation count did not reach \(expectedCount)")
}

private func makeIOSAuthSession(
    accountID: String,
    fence: String,
    protocolEpoch: UInt64,
    serverInstanceID: UUID = UUID()
) -> FuminiwaSession {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return FuminiwaSession(
        binding: AuthSessionBinding(
            serverInstanceID: serverInstanceID,
            syncProtocolEpoch: protocolEpoch,
            accountID: accountID,
            accountAuthEpoch: 1,
            accountFence: fence,
            sessionID: UUID()
        ),
        tokens: AuthSessionTokens(
            accessToken: "test-access",
            accessTokenExpiresAt: now.addingTimeInterval(900),
            refreshToken: "test-refresh",
            refreshTokenExpiresAt: now.addingTimeInterval(86400),
            refreshGeneration: 1
        ),
        receipt: AuthReceipt(
            commandKind: "exchangeApple",
            operationID: UUID(),
            replayUntil: now.addingTimeInterval(300)
        )
    )
}

@MainActor
private struct TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func releaseApplication() async {
        let key = root.standardizedFileURL
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func cleanup() {
        let key = root.standardizedFileURL
        // The store may still retain an open SQLite actor when defer runs.
        // Leave this UUID-scoped temporary root for process cleanup instead
        // of unlinking a live database from underneath the test.
        IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: key)
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
