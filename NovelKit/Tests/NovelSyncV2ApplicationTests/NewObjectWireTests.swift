import Foundation
import NovelAuth
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite(.serialized)
struct NewObjectWireTests {
    enum Recovery: CaseIterable { case none, quarantined, expiredQuarantine, edgePost, edgeReceipt, edgeUpload, edgeDownload, edgeReceiptReplay }

    @Test(arguments: Recovery.allCases, [202_375, 8 * 1024 * 1024 + 3])
    func newObjectThroughProductionWorker(recovery: Recovery, byteCount: Int) async throws {
        let config = try TestRuntimeConfiguration()
        let initialStore = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        let auth = Self.session()
        let vault = InMemoryAuthSessionVault(session: auth)
        let resolver = ProductionScopeResolver(vault: vault, store: initialStore)
        let binding = try #require(await resolver.activeBinding())
        let scope = V2LocalWorkScope.bound(binding)
        let workID = WorkID(UUID())
        _ = try await initialStore.checkpoint(V2CheckpointRequest(
            workID: workID, document: applicationTestDocument(title: "cover"),
            documentCreatedAt: applicationTestCreatedAt, expectedGeneration: 0, reason: .explicit,
            attachments: [SyncAttachment(attachmentId: UUID(), fileName: "cover.jpg", bytes: Data(repeating: 42, count: byteCount))]
        ), scope: scope)
        let edgeFault: NewObjectWireServer.EdgeFault? = switch recovery {
        case .edgePost: .post
        case .edgeReceipt: .receipt
        case .edgeUpload: .upload
        case .edgeDownload: .download
        case .edgeReceiptReplay: .receiptThenReplay
        default: nil
        }
        let server = try NewObjectWireServer(expireFirstPrepare: recovery == .expiredQuarantine, edgeFault: edgeFault)
        NewObjectWireProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewObjectWireProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let origin = try ProductionHTTPSOrigin(url: #require(URL(string: "https://new-object.test")))
        let client = ProductionSyncV2RemoteClient(origin: origin, vault: vault, session: session)
        var recoveredID: UUID?
        if recovery == .quarantined || recovery == .expiredQuarantine {
            recoveredID = try await quarantinePreparedCommand(store: initialStore, resolver: resolver, client: client, workID: workID, scope: scope)
        }
        if recoveredID != nil {
            try await initialStore.prepareLegacyRecoveryApplicationFixture()
        }
        await initialStore.close()
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .openExisting)
        let activeResolver = ProductionScopeResolver(vault: vault, store: store)
        // A fresh planner models process restart after the original quarantine.
        let planner = ProductionSyncV2Planner(store: store, scope: activeResolver)
        let kernel = ProductionSyncV2Kernel(store: store, scope: activeResolver)
        let app = try SyncV2Application(mode: .test(config), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: kernel, planner: planner, remote: client,
            gate: InMemorySyncV2DocumentGate(), library: kernel
        ))
        try await app.wake(reason: .launch)
        try await eventually(timeout: .seconds(20)) {
            let records = try await store.allSealedCommands(scope: scope, workID: workID)
            return records.contains { $0.kind == .publish && $0.lifecycle == .completed }
        }
        try await eventually { await app.lanes[workID]?.workerTask == nil }
        #expect(await app.syncDebugDiagnostic(workID: workID) == nil)
        #expect(try await store.pendingIntents(scope: scope, workID: workID).isEmpty)
        #expect(try await store.allSealedCommands(scope: scope, workID: workID).allSatisfy { $0.lifecycle == .completed })
        let events = server.recordedEvents
        #expect(events.contains("prepareObject"))
        #expect(events.contains("chunk"))
        #expect(events.contains("finalizeObject"))
        #expect(events.contains("registerSnapshot"))
        #expect(events.suffix(2) == ["publish", "receipt"])
        #expect(server.expiredUploadAttempts == 0)
        if let recoveredID {
            #expect(server.recordedCommandIDs.count(where: { $0 == recoveredID }) == 2)
        }
        do {
            let inbox = try await client.downloadRemoteOnly(workID: workID)
            let cover = Data(repeating: 42, count: byteCount)
            #expect(inbox.snapshots.last?.objects[ObjectID(data: cover)] == cover)
        }
        if edgeFault != nil {
            #expect(server.injectedEdgeFailures == (recovery == .edgeReceiptReplay ? 2 : 1))
        }
        if let recoveredID {
            try await assertRecoveryTransfers(store: store, scope: scope, workID: workID, commandID: recoveredID, expired: recovery == .expiredQuarantine)
        }
        await store.close()
    }

    @Test func fakeReceiptEncoderMatchesRustBytes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SyncServerV2/tests/fixtures/prepare-object")
        let post = try Data(contentsOf: root.appendingPathComponent("applied.json"))
        let expected = try Data(contentsOf: root.appendingPathComponent("receipt.json"))
        #expect(try NewObjectWireServer.receiptEnvelope(.init(status: 201, bytes: post)) == expected)
    }

    private func quarantinePreparedCommand(
        store: LocalSyncV2Store, resolver: ProductionScopeResolver, client: ProductionSyncV2RemoteClient,
        workID: WorkID, scope: V2LocalWorkScope
    ) async throws -> UUID {
        let planner = ProductionSyncV2Planner(store: store, scope: resolver)
        for _ in 0 ..< 2 {
            guard case let .command(command) = try await planner.nextCommand(workID: workID) else {
                throw SyncV2Failure.fatal(.invalidLocalState)
            }
            let operation = try await planner.markSending(.command(SyncV2SealedRemoteCommand(command: command)), workID: workID)
            guard case let .command(receipt, _) = try await client.execute(operation) else {
                throw SyncV2Failure.receiptMismatch
            }
            if command.kind == .prepareObject {
                // The server has committed; reproduce the device's exact durable state.
                try await store.quarantine(commandID: command.commandId, scope: scope, reason: "unexpected")
                #expect(try await store.receiptReadback(commandID: command.commandId, scope: scope) == nil)
                #expect(try await store.uploadTransfer(commandID: command.commandId, scope: scope) == nil)
                #expect(try await store.quarantinedCommandReason(workID: workID, scope: scope) == "unexpected")
                return command.commandId
            }
            try await planner.acknowledgeCommand(receipt, command: command, verifiedInboxID: nil)
        }
        throw SyncV2Failure.fatal(.invalidLocalState)
    }

    private func assertRecoveryTransfers(
        store: LocalSyncV2Store, scope: V2LocalWorkScope, workID: WorkID, commandID: UUID, expired: Bool
    ) async throws {
        let original = try #require(await store.uploadTransfer(commandID: commandID, scope: scope))
        #expect(original.acknowledgedOffset == (expired ? 0 : original.exactBytes.count))
        let records = try await store.allSealedCommands(scope: scope, workID: workID)
        var matching: [V2UploadTransferRecord] = []
        for record in records where record.kind == .prepareObject {
            if let transfer = try await store.uploadTransfer(commandID: record.commandID, scope: scope),
               transfer.objectID == original.objectID {
                matching.append(transfer)
            }
        }
        #expect(matching.count == (expired ? 2 : 1))
        #expect(Set(matching.map(\.uploadID)).count == matching.count)
        #expect(Set(matching.map(\.capability)).count == matching.count)
    }

    private static func session() -> FuminiwaSession {
        FuminiwaSession(
            binding: AuthSessionBinding(serverInstanceID: UUID(), syncProtocolEpoch: 2, accountID: "test-account", accountAuthEpoch: 1, accountFence: "test-fence", sessionID: UUID()),
            tokens: AuthSessionTokens(accessToken: "synthetic", accessTokenExpiresAt: .distantFuture, refreshToken: "synthetic", refreshTokenExpiresAt: .distantFuture, refreshGeneration: 1),
            receipt: AuthReceipt(commandKind: "test", operationID: UUID(), replayUntil: .distantFuture)
        )
    }
}
