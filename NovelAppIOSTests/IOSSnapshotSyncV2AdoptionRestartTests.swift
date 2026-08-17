@testable import EditorKit
import Foundation
@testable import FUMINIWAIOS
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@MainActor
@Suite("iOS Snapshot Sync v2 pending adoption restart", .serialized)
struct IOSSnapshotSyncV2AdoptionRestartTests {
    @Test("clean active work adopts a durable server choice after restart resume")
    func cleanResumeAdoptsAfterRestart() async throws {
        try await withAdoptionEnvironment { environment in
            let fixture = try await makePendingAdoptionFixture()
            environment.track(fixture.configuration)
            let store = makeStore(environment: environment, fixture: fixture)
            let application = try await installPendingWork(fixture, into: store)

            #expect(store.document.title == "端末版")
            await store.resumeSnapshotSyncV2()

            try await eventually {
                let pending = try await application.pendingAdoption(workID: fixture.workID)
                return store.document.title == "サーバー版"
                    && pending == nil
                    && store.snapshotSyncConflict == nil
                    && store.snapshotSyncOutcome == .idle
            }
            #expect(store.snapshotSyncConflict == nil)
            #expect(store.snapshotSyncOutcome == .idle)
        }
    }

    @Test("opening a non-active shelf work adopts ready server bytes once")
    func cleanShelfOpenAdoptsAfterRestart() async throws {
        try await withAdoptionEnvironment { environment in
            let fixture = try await makePendingAdoptionFixture()
            environment.track(fixture.configuration)
            let store = makeStore(environment: environment, fixture: fixture)
            #expect(await store.configureSnapshotSyncV2())
            let application = try #require(store.snapshotSyncV2Application)
            await store.refreshSnapshotSyncV2Projection()
            #expect(store.syncV2ActiveWorkID == nil)
            #expect(store.syncV2LibraryItems.contains { $0.workID == fixture.workID })

            #expect(await store.openSnapshotSyncV2(workID: fixture.workID.rawValue))

            try await eventually {
                let pending = try await application.pendingAdoption(workID: fixture.workID)
                return store.document.title == "サーバー版" && pending == nil
            }
            #expect(store.snapshotSyncConflict == nil)
        }
    }

    @Test("dirty edits keep durable adoption in the Inbox after restart resume")
    func dirtyResumeKeepsPendingAdoption() async throws {
        try await withAdoptionEnvironment { environment in
            let fixture = try await makePendingAdoptionFixture()
            environment.track(fixture.configuration)
            let store = makeStore(environment: environment, fixture: fixture)
            let application = try await installPendingWork(fixture, into: store)
            store.updateDocumentTitle("再起動後の追加入力")
            #expect(store.saveState == .dirty)

            await store.resumeSnapshotSyncV2()
            try await Task.sleep(nanoseconds: 100_000_000)

            #expect(store.document.title == "再起動後の追加入力")
            #expect(try await application.pendingAdoption(workID: fixture.workID) != nil)
            #expect(store.snapshotSyncState?.conflict == nil)
            guard let progress = store.snapshotSyncState?.remoteProgress,
                  case .readyForSafeAdoption = progress else {
                Issue.record("pending adoption did not remain available in the Inbox")
                return
            }
        }
    }

    @Test("active IME composition keeps durable adoption in the Inbox")
    func compositionResumeKeepsPendingAdoption() async throws {
        try await withAdoptionEnvironment { environment in
            let fixture = try await makePendingAdoptionFixture()
            environment.track(fixture.configuration)
            let editorSession = EditorCommandSession()
            let surface = EditorSurfaceToken()
            editorSession.activateEditorSurface(surface)
            #expect(editorSession.registerCommittedTextCaptureHandler(for: surface) {
                .compositionInProgress
            })
            let store = makeStore(
                environment: environment,
                fixture: fixture,
                editorCommandSession: editorSession
            )
            let application = try await installPendingWork(fixture, into: store)

            await store.resumeSnapshotSyncV2()
            try await Task.sleep(nanoseconds: 100_000_000)

            #expect(store.document.title == "端末版")
            #expect(try await application.pendingAdoption(workID: fixture.workID) != nil)
            #expect(editorSession.captureActiveCommittedText() == .compositionInProgress)
        }
    }

    @Test("a changed document session cannot install a restarted adoption")
    func sessionChangeKeepsPendingAdoption() async throws {
        try await withAdoptionEnvironment { environment in
            let fixture = try await makePendingAdoptionFixture()
            environment.track(fixture.configuration)
            let store = makeStore(environment: environment, fixture: fixture)
            let application = try await installPendingWork(fixture, into: store)
            let originalSession = try #require(store.currentDocumentSessionToken)

            await store.resumeSnapshotSyncV2()
            store.advanceDocumentSessionGeneration()
            try await Task.sleep(nanoseconds: 100_000_000)

            #expect(store.currentDocumentSessionToken != originalSession)
            #expect(store.document.title == "端末版")
            #expect(try await application.pendingAdoption(workID: fixture.workID) != nil)
        }
    }

    @Test("an account fence change invalidates a queued adoption before install")
    func accountFenceChangeKeepsPendingAdoption() async throws {
        try await withAdoptionEnvironment { environment in
            let fixture = try await makePendingAdoptionFixture()
            environment.track(fixture.configuration)
            let store = makeStore(environment: environment, fixture: fixture)
            store.authSession = makeAuthSession(accountID: "test-account", fence: "test-fence")
            let application = try await installPendingWork(fixture, into: store)
            let expectedSession = try #require(store.currentDocumentSessionToken)
            let expectedGeneration = store.localEditGeneration
            let expectedScope = store.snapshotSyncV2AccountScope
            let gate = AdoptionOperationGate()
            let blocker = Task { @MainActor in
                await store.documentOperationGate.perform {
                    await gate.signalStarted()
                    await gate.waitForRelease()
                }
            }
            await gate.waitForStart()
            let adoption = Task { @MainActor in
                await store.adoptPendingSnapshotSyncV2(
                    expectedSession: expectedSession,
                    expectedEditGeneration: expectedGeneration,
                    expectedAccountScope: expectedScope
                )
            }

            store.invalidateSnapshotSyncV2AccountOperations()
            store.authSession = makeAuthSession(accountID: "other-account", fence: "other-fence")
            await gate.release()
            await blocker.value

            #expect(await adoption.value == false)
            #expect(store.document.title == "端末版")
            #expect(try await application.pendingAdoption(workID: fixture.workID) != nil)
        }
    }

    @Test("an old account catalog page cannot repopulate the switched shelf")
    func staleAccountCatalogPageIsIgnored() throws {
        let id = UUID().uuidString
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.catalog.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-catalog-\(id)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        store.authSession = makeAuthSession(accountID: "old-account", fence: "old-fence")
        store.authUIState = .signedIn(accountID: "old-account")
        store.libraryRefreshGeneration = 7
        store.historyRefreshGeneration = 11
        let expectedScope = store.snapshotSyncV2AccountScope
        let staleItem = SyncV2RemoteCatalogEntry(
            workID: WorkID(UUID()),
            title: "旧アカウントの作品",
            head: nil
        )
        let staleLocalItem = SyncV2LibraryItem(
            workID: staleItem.workID,
            title: staleItem.title,
            availability: .cached,
            accountState: .active
        )
        store.syncV2HistoryWorkID = staleItem.workID

        store.invalidateSnapshotSyncV2AccountOperations()
        store.authSession = makeAuthSession(accountID: "new-account", fence: "new-fence")
        store.authUIState = .signedIn(accountID: "new-account")

        #expect(store.applySnapshotSyncV2LibraryProjection(
            SyncV2LibraryProjection(items: [staleLocalItem]),
            expectedAccountScope: expectedScope,
            refreshGeneration: 7
        ) == false)
        #expect(store.applySnapshotSyncV2RemoteCatalogPage(
            remoteItems: [staleItem],
            nextCursor: nil,
            localProjection: SyncV2LibraryProjection(items: []),
            expectedAccountScope: expectedScope,
            refreshGeneration: 7
        ) == false)
        #expect(store.applySnapshotSyncV2HistoryPage(
            SyncV2HistoryPage(
                items: [],
                nextCursor: "stale-cursor",
                localAvailability: .available,
                onlineAvailability: .available
            ),
            existingItems: [],
            workID: staleItem.workID,
            expectedAccountScope: expectedScope,
            refreshGeneration: 11
        ) == false)
        #expect(store.syncV2RemoteCatalogItems.isEmpty)
        #expect(store.syncV2LibraryItems.isEmpty)
        #expect(store.syncV2HistoryItems.isEmpty)
        #expect(store.syncV2HistoryCursor == nil)
    }

    @Test("remote-only response must retain the requested WorkID")
    func remoteOnlyWorkIDMismatchIsRejected() {
        let requested = WorkID(UUID())
        let opened = SyncV2OpenedWork(
            workID: WorkID(UUID()),
            document: NovelDocument.newDocument(title: "別の作品"),
            documentCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: 1,
            snapshotID: nil
        )

        #expect(acceptsSnapshotSyncV2RemoteOnlyOpen(opened, requestedWorkID: requested) == false)
    }

    private func makeStore(
        environment: AdoptionTestEnvironment,
        fixture: PendingAdoptionFixture,
        editorCommandSession: EditorCommandSession = EditorCommandSession()
    ) -> IOSDocumentStore {
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            editorCommandSession: editorCommandSession,
            libraryRoot: environment.root,
            runtimeComposition: .test(fixture.configuration)
        )
        store.authSession = makeAuthSession(
            accountID: "test-account",
            fence: "test-fence"
        )
        store.authUIState = .signedIn(accountID: "test-account")
        return store
    }

    private func installPendingWork(
        _ fixture: PendingAdoptionFixture,
        into store: IOSDocumentStore
    ) async throws -> SyncV2Application {
        #expect(await store.configureSnapshotSyncV2())
        let application = try #require(store.snapshotSyncV2Application)
        let opened = try await application.openLocal(workID: fixture.workID)
        let document = try #require(opened.document)
        #expect(store.installSnapshotSyncV2Opened(opened, value: document))
        await store.applySnapshotSyncV2State(application.uiState(workID: fixture.workID))
        guard let progress = store.snapshotSyncState?.remoteProgress,
              case .readyForSafeAdoption = progress else {
            Issue.record("restart did not project the durable pending adoption")
            throw AdoptionTestError.pendingAdoptionMissing
        }
        return application
    }

    private func eventually(
        _ condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        for _ in 0 ..< 100 {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("condition did not become true")
        throw AdoptionTestError.timedOut
    }
}

private actor AdoptionOperationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func makeAuthSession(accountID: String, fence: String) -> FuminiwaSession {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return FuminiwaSession(
        binding: AuthSessionBinding(
            serverInstanceID: UUID(),
            syncProtocolEpoch: 2,
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

private struct PendingAdoptionFixture: Sendable {
    let configuration: TestRuntimeConfiguration
    let workID: WorkID
}

private enum AdoptionTestError: Error {
    case pendingAdoptionMissing
    case timedOut
}

private func makePendingAdoptionFixture() async throws -> PendingAdoptionFixture {
    let configuration = try TestRuntimeConfiguration()
    let binding = V2AccountBinding(
        accountID: "test-account",
        accountFence: "test-fence",
        serverInstanceID: "test-server"
    )
    let scope = V2LocalWorkScope.bound(binding)
    let store = try LocalSyncV2Store(
        root: configuration.localRoot.url,
        policy: .createNew
    )
    let workID = WorkID(UUID())
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let localDocument = NovelDocument.newDocument(title: "端末版")
    let local = try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: localDocument,
            documentCreatedAt: createdAt
        ),
        parents: []
    )
    let localHead = try V2RemoteHead(snapshotID: local.snapshotId, generation: 1)
    let localInbox = V2RemoteSnapshot(
        workID: workID,
        encoded: local,
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: localHead
    )
    try await store.stageRemote(localInbox, scope: scope)
    try await store.verifyInbox(inboxID: localInbox.inboxID, scope: scope)
    try await store.adoptInbox(inboxID: localInbox.inboxID, scope: scope)

    var remoteDocument = localDocument
    remoteDocument.title = "サーバー版"
    let remote = try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: remoteDocument,
            documentCreatedAt: createdAt
        ),
        parents: []
    )
    let remoteHead = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
    let remoteInbox = V2RemoteSnapshot(
        workID: workID,
        encoded: remote,
        expectedCurrentSnapshotID: local.snapshotId,
        expectedLocalGeneration: 1,
        expectedRemoteHead: remoteHead
    )
    let conflict = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: nil,
        localSnapshotID: local.snapshotId,
        remote: remoteInbox,
        sourceGeneration: 1,
        scope: scope
    )
    let preparation = try await store.prepareUseServer(
        V2ServerResolutionRequest(
            workID: workID,
            conflictID: conflict.conflictID,
            revision: conflict.revision,
            sourceGeneration: conflict.sourceGeneration,
            localSnapshotID: conflict.localSnapshotID,
            remoteSnapshotID: conflict.remoteSnapshotID,
            inboxID: remoteInbox.inboxID,
            expectedRemoteHead: remoteHead
        ),
        scope: scope
    )
    guard preparation.intentID != nil else {
        throw AdoptionTestError.pendingAdoptionMissing
    }
    await store.close()

    await configuration.remote.setCommandHandler { command in
        try makeResolveServerExecution(command, remoteHead: remoteHead)
    }
    var firstRuntime: SyncV2Application? = try await SnapshotSyncV2Runtime.makeApplication(
        mode: .test(configuration)
    )
    for _ in 0 ..< 100 {
        if try await firstRuntime?.pendingAdoption(workID: workID) != nil {
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard try await firstRuntime?.pendingAdoption(workID: workID) != nil else {
        throw AdoptionTestError.pendingAdoptionMissing
    }
    firstRuntime = nil
    try await Task.sleep(nanoseconds: 50_000_000)
    return PendingAdoptionFixture(configuration: configuration, workID: workID)
}

private func makeResolveServerExecution(
    _ command: SyncV2SealedRemoteCommand,
    remoteHead: V2RemoteHead
) throws -> SyncV2RemoteExecution {
    guard command.kind == .resolveServer else {
        throw SyncV2Failure.offline
    }
    let sealed = command.command
    guard let envelope = try JSONSerialization.jsonObject(with: sealed.canonicalBytes) as? [String: Any],
          let payload = envelope["payload"] as? [String: Any],
          let workID = payload["workId"] as? String,
          let conflictID = payload["conflictId"] as? String,
          let conflictRevision = payload["conflictRevision"] as? NSNumber,
          let remoteSnapshotID = payload["remoteSnapshotId"] as? String else {
        throw SyncV2Failure.receiptMismatch
    }
    let readBack: [String: Any] = [
        "accountMatched": true,
        "commandDigestMatched": true,
        "headMatched": true,
        "resourceMatched": true,
        "stateMatched": true
    ]
    let receipt: [String: Any] = [
        "commandId": sealed.commandId.uuidString.lowercased(),
        "commandKind": sealed.commandKind,
        "readBack": readBack,
        "requestDigest": sealed.requestDigest.rawValue,
        "workId": workID
    ]
    let head: [String: Any] = [
        "generation": remoteHead.generation,
        "snapshotId": remoteHead.snapshotID.rawValue
    ]
    let response = try canonicalJSON([
        "commandId": sealed.commandId.uuidString.lowercased(),
        "commandKind": sealed.commandKind,
        "conflictId": conflictID,
        "conflictRevision": conflictRevision,
        "head": head,
        "receipt": receipt,
        "remoteGeneration": remoteHead.generation,
        "remoteSnapshotId": remoteSnapshotID,
        "result": "applied"
    ])
    let canonicalReceipt = try canonicalJSON([
        "canonicalResponseBase64URL": response.base64URLString,
        "commandId": sealed.commandId.uuidString.lowercased(),
        "commandKind": sealed.commandKind,
        "originalResponseStatus": 200,
        "originalResult": "applied",
        "readBack": readBack,
        "requestDigest": sealed.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ])
    return try .command(
        receipt: SyncV2ReceiptReadback(
            commandID: sealed.commandId,
            requestDigest: sealed.requestDigest,
            responseStatus: 200,
            canonicalResponse: canonicalReceipt,
            predicates: SyncV2ReadBackPredicates(
                accountMatched: true,
                commandDigestMatched: true,
                resourceMatched: true,
                headMatched: true,
                stateMatched: true
            ),
            result: .applied,
            remoteHead: SyncV2RemoteHead(
                snapshotID: remoteHead.snapshotID,
                generation: remoteHead.generation
            )
        ),
        remoteInbox: nil
    )
}

private func canonicalJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class AdoptionTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    init(root: URL, defaults: UserDefaults, suiteName: String) {
        self.root = root
        self.defaults = defaults
        self.suiteName = suiteName
    }

    func track(_: TestRuntimeConfiguration) {}

    func cleanup() async {
        let key = root.standardizedFileURL
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: key)
        // SyncV2Application owns long-lived worker/SQLite actors and has no
        // public close boundary. Removing their roots here can unlink an open
        // database and prevent the app-host harness from finalizing. TestRoot
        // directories are uniquely named OS-temporary artifacts, so leave
        // filesystem reclamation to the platform after releasing our cache.
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func withAdoptionEnvironment(
    _ operation: (AdoptionTestEnvironment) async throws -> Void
) async throws {
    let id = UUID().uuidString
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FUMINIWA-iOS-adoption-\(id)", isDirectory: true)
    let suiteName = "dev.serikayuzuki.fuminiwa.ios.adoption.\(id)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let environment = AdoptionTestEnvironment(
        root: root,
        defaults: defaults,
        suiteName: suiteName
    )
    do {
        try await operation(environment)
        await environment.cleanup()
    } catch {
        await environment.cleanup()
        throw error
    }
}
