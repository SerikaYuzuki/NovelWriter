import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import Testing

@Suite("Snapshot Sync v2 application")
struct ApplicationTests {
    @Test("checkpoint returns after local durability and does not await transport")
    func checkpointIsLocalFirst() async throws {
        let kernel = TestKernel()
        let transport = BlockingTransport()
        let app = SyncV2Application(kernel: kernel, transport: transport)
        let workID = WorkID(UUID())
        let result = try await app.checkpoint(
            workID: workID,
            document: NovelDocument(title: "test", chapters: []),
            reason: .explicit
        )
        #expect(result.state.localDurability != SyncV2LocalDurability.failed)
        #expect(result.typedResult == SyncV2TypedResult.checkpointed)
        #expect(await transport.sendCount() == 0)
    }

    @Test("synchronize with no pending work is successful noChanges")
    func noOpSyncIsSuccess() async throws {
        let app = SyncV2Application(kernel: TestKernel(), transport: BlockingTransport())
        let workID = WorkID(UUID())
        _ = try await app.checkpoint(
            workID: workID,
            document: NovelDocument(title: "test", chapters: []),
            reason: .explicit
        )
        let result = try await app.synchronize(workID: workID)
        #expect(result.typedResult == SyncV2TypedResult.noChanges)
        #expect(result.state.japaneseLabel == "同期済み")
    }

    @Test("runtime mode keeps test dependencies physically distinct")
    func runtimeIsolation() throws {
        let root = try TestRoot(url: URL(fileURLWithPath: "/tmp/fuminiwa-v2-test"))
        let dependencies = TestDependencies(
            root: root,
            transport: FakeTransport(),
            vault: TestVault(),
            defaults: TestDefaults(),
            account: TestAccount(accountID: "test", accountFence: "fence"),
            kernel: TestKernel()
        )
        _ = try SyncV2Application(mode: .test(dependencies))
    }

    @Test("safe adoption rejects IME and unsaved boundaries")
    func safeBoundaryRejectsUnsafeState() async throws {
        let app = SyncV2Application(kernel: TestKernel(), transport: BlockingTransport())
        let workID = WorkID(UUID())
        let token = await app.beginSession(workID: workID)
        let boundary = SafeAdoptionBoundary(
            workID: workID,
            sessionToken: token,
            expectedGeneration: 0,
            expectedSnapshotID: nil,
            imeActive: true,
            hasUnsavedChanges: false,
            hasPendingIntent: false,
            documentGateProof: UUID()
        )
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await app.applyStagedRemote(at: boundary)
        }
    }
}

private actor BlockingTransport: SyncV2Transport {
    private var count = 0

    func send(_ request: SyncV2TransportRequest) async throws -> SyncV2TransportResponse {
        _ = request
        count += 1
        throw SyncV2ApplicationError.transport("blocked")
    }

    func sendCount() -> Int {
        count
    }
}

private actor TestKernel: SyncV2LocalKernel {
    private var work: [WorkID: SyncV2OpenedWork] = [:]

    func checkpoint(_ capture: SyncV2CheckpointCapture) async throws -> SyncV2LocalCheckpoint {
        let model = try SnapshotCodec.decode(
            manifestBytes: capture.encoded.manifestBytes,
            objects: capture.encoded.objects
        )
        let previous = work[capture.workID]
        let generation = (previous?.generation ?? 0) + 1
        work[capture.workID] = SyncV2OpenedWork(
            workID: capture.workID,
            document: model.document,
            generation: generation,
            snapshotID: capture.encoded.snapshotId
        )
        return SyncV2LocalCheckpoint(
            snapshotID: capture.encoded.snapshotId,
            generation: generation,
            intentID: UUID(),
            noChanges: false
        )
    }

    func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        guard let value = work[workID] else { throw SyncV2ApplicationError.workNotFound }
        return value
    }

    func pendingCommands(workID: WorkID) async throws -> [SealedCommand] {
        _ = workID
        return []
    }

    func markSending(commandID: UUID, workID: WorkID) async throws -> SealedCommand {
        _ = commandID
        _ = workID
        throw SyncV2ApplicationError.workNotFound
    }

    func requeue(commandID: UUID, workID: WorkID) async throws {
        _ = commandID
        _ = workID
    }

    func acknowledge(_ receipt: SyncV2ReceiptReadback, command: SealedCommand, verifiedInboxID: UUID?) async throws {
        _ = receipt
        _ = command
        _ = verifiedInboxID
    }

    func prepareConflict(_ action: SyncV2ConflictAction) async throws -> SealedCommand {
        _ = action
        throw SyncV2ApplicationError.staleConflictAction
    }

    func prepareRestore(_ request: SyncV2RestoreRequest) async throws -> SealedCommand? {
        _ = request
        return nil
    }

    func stageRemote(_ inbox: SyncV2RemoteInbox) async throws {
        _ = inbox
    }

    func verifyRemote(inboxID: UUID, workID: WorkID) async throws {
        _ = inboxID
        _ = workID
    }

    func applyStagedRemote(_ boundary: SafeAdoptionBoundary) async throws -> SyncV2OpenedWork {
        try await open(workID: boundary.workID)
    }
}
