import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Suite("macOS Snapshot Sync v2 composition")
struct SnapshotSyncV2MacTests {
    @Test("active v2 session keeps WorkID separate from DocumentID")
    @MainActor
    func activeSessionUsesExplicitWorkID() throws {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacTests.identity.\(UUID().uuidString)"))
        let state = AppState(
            dependencies: AppDependencies(userDefaults: defaults)
        )
        let document = NovelDocument.newDocument()
        let workID = WorkID(UUID())
        #expect(workID.rawValue != document.id)

        state.installV2Document(document, workID: workID, createdAt: Date())

        #expect(state.snapshotSyncV2ActiveWorkID == workID)
        #expect(state.documentSessionToken.workID == workID)
        #expect(state.documentSessionToken.documentID == document.id)
        #expect(defaults.string(forKey: "fuminiwa.v2.activeWorkID") == workID.rawValue.uuidString)
    }

    @Test("test runtime uses an isolated temporary root")
    func runtimeDoesNotUseProductionPersistence() throws {
        let configuration = try TestRuntimeConfiguration()
        #expect(configuration.localRoot.url.path.contains("FUMINIWA-SnapshotSyncV2-Tests"))
        #expect(!configuration.localRoot.url.path.contains("Application Support"))
        #expect(configuration.defaults.suiteName.contains("sync-v2.tests"))
    }

    @Test("ready editor without an active WorkID fails closed")
    @MainActor
    func readyStateDoesNotFallBackToDocumentID() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: makeIsolatedTestUserDefaults(),
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            ),
            initialStartupState: .ready
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        state.markDocumentDirty()
        #expect(await state.saveNow() == false)
        #expect(state.snapshotSyncV2ActiveWorkID == nil)
    }

    @Test("offline checkpoint and close remain local boundaries")
    @MainActor
    func offlineCheckpointOpenAndCloseDoNotAwaitRemote() async throws {
        let configuration = try TestRuntimeConfiguration()
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let document = NovelDocument.newDocument()
        let workID = WorkID(document.id)
        _ = await application.beginSession(workID: workID)

        let checkpoint = try await application.checkpoint(
            workID: workID,
            document: document,
            reason: .autosave,
            documentCreatedAt: Date()
        )
        #expect(checkpoint.typedResult == .checkpointed || checkpoint.typedResult == .noChanges)

        let opened = try await application.open(workID: workID)
        #expect(opened.document?.id == document.id)

        let close = try await application.checkpoint(
            workID: workID,
            document: document,
            reason: .close,
            documentCreatedAt: opened.documentCreatedAt
        )
        #expect(close.typedResult == .noChanges || close.typedResult == .checkpointed)
    }

    @Test("identical checkpoint is a successful no-op")
    func identicalCheckpointIsNoOp() async throws {
        let configuration = try TestRuntimeConfiguration()
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let document = NovelDocument.newDocument()
        let workID = WorkID(document.id)
        let createdAt = Date()

        _ = try await application.checkpoint(
            workID: workID,
            document: document,
            reason: .migration,
            documentCreatedAt: createdAt
        )
        let repeated = try await application.checkpoint(
            workID: workID,
            document: document,
            reason: .autosave,
            documentCreatedAt: createdAt
        )
        #expect(repeated.typedResult == .noChanges)
    }

    @Test("explicit synchronize treats an idle work as a successful no-op")
    func explicitSynchronizeNoOpIsSuccessful() async throws {
        let configuration = try TestRuntimeConfiguration()
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let document = NovelDocument.newDocument()
        let workID = WorkID(document.id)
        _ = try await application.checkpoint(
            workID: workID,
            document: document,
            reason: .migration,
            documentCreatedAt: Date()
        )

        let synchronized = try await application.synchronize(workID: workID)
        #expect(synchronized.typedResult == .noChanges || synchronized.typedResult == .queued)
    }

    @Test("v2 shelf deduplicates WorkID and projects remote-only entries")
    @MainActor
    func libraryProjectionKeepsLocalAndRemoteOnlyDistinct() async throws {
        let configuration = try TestRuntimeConfiguration()
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacTests.library.\(UUID().uuidString)"))
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let localWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let remoteOnlyWorkID = WorkID(UUID())
        state.snapshotSyncRemoteCatalogItems = [
            SyncV2RemoteCatalogEntry(workID: localWorkID, title: "remote title", head: nil),
            SyncV2RemoteCatalogEntry(workID: localWorkID, title: "duplicate", head: nil),
            SyncV2RemoteCatalogEntry(workID: remoteOnlyWorkID, title: "remote only", head: nil)
        ]

        await state.refreshSnapshotLibrary()

        let matching = state.snapshotSyncLibraryWorks.filter {
            $0.workID == localWorkID || $0.workID == remoteOnlyWorkID
        }
        #expect(matching.count == 2)
        #expect(matching.first(where: { $0.workID == localWorkID })?.availability == .cached)
        #expect(matching.first(where: { $0.workID == remoteOnlyWorkID })?.availability == .remoteOnly)
    }

    @Test("remote-only作品の取得待ちは作品一覧のgateを占有しない")
    @MainActor
    func remoteOnlyOpenReturnsWithoutBlockingCurrentWork() async throws {
        let configuration = try TestRuntimeConfiguration()
        let suspendedOpen = SuspendedRemoteOnlyOpen()
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacTests.remoteOnly.\(UUID().uuidString)"))
        var dependencies = AppDependencies(
            userDefaults: defaults,
            snapshotSyncV2Factory: {
                try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
            }
        )
        dependencies.snapshotSyncV2OpenOverride = { _, workID in
            await suspendedOpen.open(workID: workID)
        }
        let state = AppState(
            dependencies: dependencies
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let application = try #require(state.snapshotSyncV2Application)
        let currentWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let currentDocument = state.document
        let currentSession = state.documentSessionToken

        let secondWorkID = WorkID(UUID())
        let secondDocument = NovelDocument.newDocument(title: "取得待ち中に開く別作品")
        _ = try await application.checkpoint(
            workID: secondWorkID,
            document: secondDocument,
            reason: .migration,
            documentCreatedAt: Date()
        )
        #expect(await state.returnToSnapshotLibrary())

        let remoteOnlyWorkID = WorkID(UUID())
        state.snapshotSyncRemoteCatalogItems = [
            SyncV2RemoteCatalogEntry(workID: remoteOnlyWorkID, title: "通信待ち作品", head: nil)
        ]
        await state.refreshSnapshotLibrary()
        let remoteOnly = try #require(
            state.snapshotSyncLibraryWorks.first(where: { $0.workID == remoteOnlyWorkID })
        )
        let secondWork = try #require(
            state.snapshotSyncLibraryWorks.first(where: { $0.workID == secondWorkID })
        )
        #expect(remoteOnly.availability == .remoteOnly)

        let clock = ContinuousClock()
        let started = clock.now
        #expect(await state.openLibraryWork(remoteOnly))
        let elapsed = clock.now - started

        #expect(elapsed < .seconds(1))
        try await eventuallyMac {
            await suspendedOpen.isWaiting(for: remoteOnlyWorkID)
        }
        #expect(state.startupState.isReady == false)
        #expect(state.snapshotSyncV2ActiveWorkID == currentWorkID)
        #expect(state.document == currentDocument)
        #expect(state.documentSessionToken == currentSession)
        #expect(state.isDocumentTransitionInProgress == false)

        // A second gate operation remains available while the remote request
        // is suspended. Installing that local work cancels the stale request.
        #expect(await state.openLibraryWork(secondWork))
        #expect(state.snapshotSyncV2ActiveWorkID == secondWorkID)
        #expect(state.document.title == secondDocument.title)
        let secondSession = state.documentSessionToken
        #expect(await state.addChapterAfterTransition())
        #expect(state.documentSessionToken == secondSession)

        let delayedRemoteDocument = NovelDocument.newDocument(title: "遅れて届いた作品")
        await suspendedOpen.resume(
            returning: SyncV2OpenedWork(
                workID: remoteOnlyWorkID,
                document: delayedRemoteDocument,
                documentCreatedAt: Date(),
                generation: 1,
                snapshotID: nil
            )
        )
        try await eventuallyMac {
            state.snapshotSyncV2RemoteOnlyOpenTask == nil
        }

        #expect(state.snapshotSyncV2ActiveWorkID == secondWorkID)
        #expect(state.documentSessionToken == secondSession)
        #expect(state.document.title == secondDocument.title)
        #expect(state.operationMessage == nil)
        #expect(state.startupState.isReady)
        #expect(state.isDocumentTransitionInProgress == false)
    }

    @Test("platform gate rejects IME and unsaved adoption")
    func platformGateRejectsUnsafeProof() async throws {
        let gate = MacSyncV2DocumentGate()
        let session = await gate.beginSession(workID: WorkID(UUID()))
        let version = SyncV2LocalVersion(generation: 1, snapshotID: nil)
        await #expect(throws: SyncV2ApplicationError.self) {
            try await gate.arm(
                session: session,
                expectedLocalVersion: version,
                proof: SyncV2SafeBoundaryProof(
                    editorGeneration: 1,
                    hasMarkedText: true,
                    hasUnsavedChanges: false,
                    pendingIntentCleared: false
                )
            )
        }
    }

    @Test("添付の衝突名・削除・SQLite bytes previewを保持する")
    @MainActor
    func attachmentLifecycleUsesSnapshotBytes() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacTests.attachments.\(UUID().uuidString)"))
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("資料-\(UUID().uuidString).txt")
        let bytes = Data("資料本文".utf8)
        try bytes.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let first = try #require(await state.addAttachment(from: sourceURL))
        let second = try #require(await state.addAttachment(from: sourceURL))
        #expect(first.fileName != second.fileName)
        #expect(second.fileName.hasSuffix(" (2).txt"))

        let preview = try #require(state.attachmentPreviewURL(for: first))
        #expect(try Data(contentsOf: preview) == bytes)
        #expect(await state.deleteAttachment(first))
        #expect(state.attachments.contains(where: { $0.fileName == first.fileName }) == false)

        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("空資料-\(UUID().uuidString).txt")
        try Data().write(to: emptyURL)
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let empty = try #require(await state.addAttachment(from: emptyURL))
        #expect(empty.byteCount == 0)
        let beforeFailedAdd = state.attachments
        let beforeFailedPayloads = state.snapshotSyncV2Attachments
        state.snapshotSyncV2Application = nil
        #expect(await state.addAttachment(from: sourceURL) == nil)
        #expect(state.attachments == beforeFailedAdd)
        #expect(state.snapshotSyncV2Attachments == beforeFailedPayloads)
    }
}

private actor SuspendedRemoteOnlyOpen {
    private var waitingWorkID: WorkID?
    private var continuation: CheckedContinuation<SyncV2OpenedWork, Never>?

    func open(workID: WorkID) async -> SyncV2OpenedWork {
        waitingWorkID = workID
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting(for workID: WorkID) -> Bool {
        waitingWorkID == workID && continuation != nil
    }

    func resume(returning opened: SyncV2OpenedWork) {
        waitingWorkID = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: opened)
    }
}

struct MacConflictFixture {
    let configuration: TestRuntimeConfiguration
    let application: SyncV2Application
    let remote: FakeSyncV2RemoteClient
    let state: AppState
    let workID: WorkID
    let document: NovelDocument
    let remoteDocument: NovelDocument
    let projection: SyncV2ConflictProjection
    let inboxID: UUID
    let serverInbox: SyncV2RemoteInbox

    func action(choice: SyncV2ConflictChoice) -> SyncV2ConflictAction {
        SyncV2ConflictAction(
            workID: workID,
            conflictID: projection.conflictID,
            revision: projection.revision,
            baseSnapshotID: projection.baseSnapshotID,
            localSnapshotID: projection.localSnapshotID,
            remoteSnapshotID: projection.remoteSnapshotID,
            sourceGeneration: projection.sourceGeneration,
            choice: choice,
            newWorkID: choice == .keepBoth ? WorkID(UUID()) : nil,
            newDocumentID: choice == .keepBoth ? DocumentID(UUID()) : nil
        )
    }
}

private struct MacConflictKernel {
    let application: SyncV2Application
    let remote: FakeSyncV2RemoteClient
    let storage: MacConflictStorage
}

private struct MacConflictStorage {
    let workID: WorkID
    let createdAt: Date
    let document: NovelDocument
    let remoteDocument: NovelDocument
    let projection: SyncV2ConflictProjection
    let inboxID: UUID
    let serverInbox: SyncV2RemoteInbox
}

private struct MacConflictDocuments {
    let workID: WorkID
    let createdAt: Date
    let document: NovelDocument
    let remoteDocument: NovelDocument
}

private func makeMacConflictDocuments() -> MacConflictDocuments {
    let workID = WorkID(UUID())
    let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
    let documentID = DocumentID(UUID())
    let document = NovelDocument(
        id: documentID.rawValue,
        title: "端末版",
        chapters: [Chapter(title: "第一章", content: "本文")]
    )
    let remoteDocument = NovelDocument(
        id: documentID.rawValue,
        title: "サーバー版",
        chapters: [Chapter(title: "第一章", content: "サーバー本文")]
    )
    return MacConflictDocuments(
        workID: workID,
        createdAt: createdAt,
        document: document,
        remoteDocument: remoteDocument
    )
}

private func makeMacConflictRemoteSnapshot(
    documents: MacConflictDocuments,
    checkpoint: V2CheckpointResult,
    inboxID: UUID
) throws -> V2RemoteSnapshot {
    let encodedRemote = try SnapshotCodec.encode(
        SnapshotModel(
            workId: documents.workID,
            document: documents.remoteDocument,
            documentCreatedAt: documents.createdAt
        ),
        parents: []
    )
    let expectedRemoteHead = try V2RemoteHead(snapshotID: encodedRemote.snapshotId, generation: 1)
    return V2RemoteSnapshot(
        inboxID: inboxID,
        workID: documents.workID,
        encoded: encodedRemote,
        expectedCurrentSnapshotID: checkpoint.snapshotID,
        expectedLocalGeneration: checkpoint.generation,
        expectedRemoteHead: expectedRemoteHead
    )
}

private func makeMacConflictStorage(
    configuration: TestRuntimeConfiguration
) async throws -> MacConflictStorage {
    let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
    let scope = V2LocalWorkScope.bound(
        V2AccountBinding(
            accountID: "test-account",
            accountFence: "test-fence",
            serverInstanceID: "test-server"
        )
    )
    let documents = makeMacConflictDocuments()
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: documents.workID,
            document: documents.document,
            documentCreatedAt: documents.createdAt,
            expectedGeneration: 0,
            reason: .migration
        ),
        scope: scope
    )
    let inboxID = UUID()
    let remoteSnapshot = try makeMacConflictRemoteSnapshot(
        documents: documents,
        checkpoint: checkpoint,
        inboxID: inboxID
    )
    let expectedRemoteHead = try SyncV2RemoteHead(
        snapshotID: remoteSnapshot.encoded.snapshotId,
        generation: 1
    )
    let serverInbox = SyncV2RemoteInbox(
        inboxID: remoteSnapshot.inboxID,
        workID: remoteSnapshot.workID,
        headSnapshotID: remoteSnapshot.encoded.snapshotId,
        snapshots: [remoteSnapshot.encoded],
        expectedCurrentSnapshotID: remoteSnapshot.expectedCurrentSnapshotID,
        expectedLocalGeneration: remoteSnapshot.expectedLocalGeneration,
        expectedRemoteHead: expectedRemoteHead
    )
    let candidate = try await store.appendConflict(
        workID: documents.workID,
        baseSnapshotID: nil,
        localSnapshotID: checkpoint.snapshotID,
        remote: remoteSnapshot,
        sourceGeneration: checkpoint.generation,
        scope: scope
    )
    await store.close()
    return MacConflictStorage(
        workID: documents.workID,
        createdAt: documents.createdAt,
        document: documents.document,
        remoteDocument: documents.remoteDocument,
        projection: SyncV2ConflictProjection(
            conflictID: candidate.conflictID,
            revision: candidate.revision,
            baseSnapshotID: candidate.baseSnapshotID,
            localSnapshotID: candidate.localSnapshotID,
            remoteSnapshotID: candidate.remoteSnapshotID,
            sourceGeneration: candidate.sourceGeneration
        ),
        inboxID: inboxID,
        serverInbox: serverInbox
    )
}

private func makeMacConflictKernel(
    configuration: TestRuntimeConfiguration
) async throws -> MacConflictKernel {
    let remote = configuration.remote
    let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
    let storage = try await makeMacConflictStorage(configuration: configuration)
    await application.setState(
        workID: storage.workID,
        localDurability: .saved(generation: 1, snapshotID: storage.projection.localSnapshotID),
        remoteProgress: .needsChoice,
        result: .conflictPending,
        conflict: .set(storage.projection)
    )
    return MacConflictKernel(
        application: application,
        remote: remote,
        storage: storage
    )
}

@MainActor
func makeMacConflictFixture(
    remoteBehavior: FakeSyncV2RemoteClient.Behavior,
    committedText: String? = nil,
    committedCapture: EditorCommittedTextCaptureResult? = nil,
    afterStagedRemote: SnapshotSyncV2AfterStagedRemoteOverride? = nil
) async throws -> MacConflictFixture {
    let configuration = try TestRuntimeConfiguration()
    let kernel = try await makeMacConflictKernel(configuration: configuration)
    await kernel.remote.setBehaviors([remoteBehavior])

    let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacTests.conflict.\(UUID().uuidString)"))
    var dependencies = AppDependencies(
        userDefaults: defaults,
        activeCommittedTextCapture: {
            committedCapture ?? .captured(
                committedText ?? kernel.storage.document.chapters.first?.episodes.first?.content ?? ""
            )
        },
        snapshotSyncV2DocumentGate: MacSyncV2DocumentGate()
    )
    dependencies.snapshotSyncV2AfterStagedRemoteOverride = afterStagedRemote
    let state = AppState(dependencies: dependencies, initialStartupState: .ready)
    state.snapshotSyncV2Application = kernel.application
    state.installV2Document(
        kernel.storage.document,
        workID: kernel.storage.workID,
        createdAt: kernel.storage.createdAt
    )
    state.snapshotSyncV2Session = await kernel.application.beginSession(workID: kernel.storage.workID)
    return MacConflictFixture(
        configuration: configuration,
        application: kernel.application,
        remote: kernel.remote,
        state: state,
        workID: kernel.storage.workID,
        document: kernel.storage.document,
        remoteDocument: kernel.storage.remoteDocument,
        projection: kernel.storage.projection,
        inboxID: kernel.storage.inboxID,
        serverInbox: kernel.storage.serverInbox
    )
}

@MainActor
func eventuallyMac(
    timeout: Duration = .seconds(2),
    stablePolls: Int = 1,
    condition: @escaping @MainActor @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var consecutiveMatches = 0
    while clock.now < deadline {
        if try await condition() {
            consecutiveMatches += 1
            if consecutiveMatches >= max(stablePolls, 1) {
                return
            }
        } else {
            consecutiveMatches = 0
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition did not become true before timeout")
}
