import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
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

    @Test("all three conflict choices remain explicit")
    func conflictActionsPreserveThreeChoices() throws {
        let workID = WorkID(UUID())
        let conflictID = UUID()
        let local = try SnapshotID(rawValue: String(repeating: "a", count: 64))
        let remote = try SnapshotID(rawValue: String(repeating: "b", count: 64))
        let choices: [SyncV2ConflictChoice] = [.useDevice, .useServer, .keepBoth]
        let actions = choices.map {
            SyncV2ConflictAction(
                workID: workID,
                conflictID: conflictID,
                revision: 1,
                baseSnapshotID: nil,
                localSnapshotID: local,
                remoteSnapshotID: remote,
                sourceGeneration: 1,
                choice: $0
            )
        }
        #expect(actions.map(\.choice) == choices)
    }

    @Test("keep-both returned work is installed before the worker wake")
    @MainActor
    func keepBothOpenedWorkHandsOffTheEditorBeforeResume() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(
            dependencies: AppDependencies(),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = application

        let source = NovelDocument.newDocument()
        let sourceWorkID = WorkID(UUID())
        let sourceCreatedAt = Date()
        state.installV2Document(source, workID: sourceWorkID, createdAt: sourceCreatedAt)
        _ = try await application.checkpoint(
            workID: sourceWorkID,
            document: source,
            reason: .migration,
            documentCreatedAt: sourceCreatedAt
        )
        state.snapshotSyncV2Session = await application.beginSession(workID: sourceWorkID)

        var clone = source
        clone.title = "keep-both clone"
        let cloneWorkID = WorkID(UUID())
        let opened = SyncV2OpenedWork(
            workID: cloneWorkID,
            document: clone,
            documentCreatedAt: Date(),
            generation: 1,
            snapshotID: nil
        )

        #expect(await state.installKeepBothOpenedWork(opened, using: application))
        #expect(state.snapshotSyncV2ActiveWorkID == cloneWorkID)
        #expect(state.documentSessionToken.workID == cloneWorkID)
        #expect(state.document.title == "keep-both clone")
        #expect(state.snapshotSyncV2Session?.workID == cloneWorkID)
    }

    @Test("競合の版選択はdirty本文を暗黙checkpointしない")
    @MainActor
    func conflictChoiceDoesNotCheckpointDirtyEditor() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(
            dependencies: AppDependencies(),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument()
        let workID = WorkID(UUID())
        let createdAt = Date()
        state.installV2Document(document, workID: workID, createdAt: createdAt)
        state.snapshotSyncV2Session = await application.beginSession(workID: workID)
        _ = try await application.checkpoint(
            workID: workID,
            document: document,
            reason: .migration,
            documentCreatedAt: createdAt
        )
        state.markDocumentDirty()

        #expect(await state.resolveSnapshotConflict(using: .useServer) == false)
        #expect(state.saveState == .unsaved)
        #expect(state.operationMessage == nil)
    }

    @Test("v2 shelf deduplicates WorkID and projects remote-only entries")
    @MainActor
    func libraryProjectionKeepsLocalAndRemoteOnlyDistinct() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
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
