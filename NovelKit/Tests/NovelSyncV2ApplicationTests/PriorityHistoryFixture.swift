import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

struct PriorityHistoryFixture: Sendable {
    let configuration: TestRuntimeConfiguration
    let snapshots: [EncodedSnapshot]
    let store: LocalSyncV2Store
    let kernel: ProductionSyncV2Kernel
    let remote: PriorityHistoryRemote
    let app: SyncV2Application
    var head: EncodedSnapshot {
        snapshots[snapshots.count - 1]
    }

    var workID: WorkID {
        head.manifest.workId
    }

    static func make() async throws -> Self {
        let configuration = try TestRuntimeConfiguration(account: TestAccount(accountID: "test-account", accountFence: "test-fence"))
        let snapshots = try SharedShallowFixture().snapshots
        let head = try #require(snapshots.last)
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
        let graph = V2RemoteSnapshotGraph(workID: head.manifest.workId, headSnapshotID: head.snapshotId, snapshots: [head],
                                          expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(validatedSnapshotID: head.snapshotId, generation: 1))
        try await store.installShallowHead(graph, scope: productionScope)
        let resolver = TestScopeResolver(vault: configuration.vault, store: store)
        let kernel = ProductionSyncV2Kernel(store: store, scope: resolver)
        let remote = PriorityHistoryRemote(store: store, snapshots: snapshots)
        let app = try SyncV2Application(mode: .test(configuration), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: kernel, planner: InMemorySyncV2RuntimeState(), remote: remote,
            gate: InMemorySyncV2DocumentGate(), library: kernel
        ))
        return Self(configuration: configuration, snapshots: snapshots, store: store, kernel: kernel, remote: remote, app: app)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: configuration.localRoot.url)
    }

    func workerApp(remote: any SyncV2RemoteClient, expectedHead: SnapshotID? = nil) throws -> SyncV2Application {
        let command = try productionPublishCommand(workID: workID,
                                                   checkpoint: V2CheckpointResult(snapshotID: head.snapshotId, generation: 1, intentID: nil, noChanges: false),
                                                   expectedHead: V2RemoteHead(validatedSnapshotID: expectedHead ?? head.snapshotId, generation: 1))
        return try SyncV2Application(mode: .test(configuration), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: kernel, planner: PriorityOperationPlanner(command: command), remote: remote,
            gate: InMemorySyncV2DocumentGate(), library: kernel
        ))
    }
}

actor PriorityHistoryRemote: SyncV2RemoteClient {
    let store: LocalSyncV2Store
    let snapshots: [EncodedSnapshot]
    var started = 0
    var manualRequests: [Bool] = []
    var constrainedPermissions: [Bool] = []
    private var released = false

    init(store: LocalSyncV2Store, snapshots: [EncodedSnapshot]) {
        self.store = store
        self.snapshots = snapshots
    }

    func release() {
        released = true
    }

    func backfillWorkIDs() async throws -> [WorkID] {
        try await store.backfillWorkIDs()
    }

    func backfillHistory(workID: WorkID, manual: Bool, allowConstrained: Bool = false, progress: @escaping @Sendable () async -> Void) async throws {
        guard let state = try await store.resumeBackfill(workID: workID, binding: productionBinding, manual: manual) else { return }
        started += 1
        manualRequests.append(manual)
        constrainedPermissions.append(allowConstrained)
        while !released {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await store.applyBackfillPage(V2BackfillPage(snapshots: Array(snapshots.dropLast().reversed()), resumeCursor: nil, terminal: true),
                                          workID: workID, binding: productionBinding, root: state.rootSnapshotID, expectedCursor: state.resumeCursor)
        await progress()
    }

    func execute(_: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        throw SyncV2Failure.offline
    }
}

/// The worker receives an ordinary receipt/Inbox; the real kernel performs
/// staging, validation and conflict creation. Only remote I/O and ACK storage
/// are scripted here; receipt-ledger tests cover the durable ACK separately.
actor ReceiptHistoryRemote: SyncV2RemoteClient {
    let backfill: PriorityHistoryRemote
    let reply: ApplicationTestRemote.Reply
    var attempts = 0
    init(backfill: PriorityHistoryRemote, reply: ApplicationTestRemote.Reply) {
        self.backfill = backfill
        self.reply = reply
    }

    func backfillWorkIDs() async throws -> [WorkID] {
        try await backfill.backfillWorkIDs()
    }

    func backfillHistory(workID: WorkID, manual: Bool, allowConstrained: Bool = false, progress: @escaping @Sendable () async -> Void) async throws {
        try await backfill.backfillHistory(workID: workID, manual: manual, allowConstrained: allowConstrained, progress: progress)
    }

    func execute(_ request: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        attempts += 1
        return try await ApplicationTestRemote([reply]).execute(request)
    }
}

extension PriorityHistoryFixture {
    func inbox(_ graph: V2RemoteSnapshotGraph) throws -> SyncV2RemoteInbox {
        try SyncV2RemoteInbox(inboxID: graph.inboxID, workID: workID, headSnapshotID: graph.headSnapshotID, snapshots: graph.snapshots,
                              expectedCurrentSnapshotID: head.snapshotId, expectedLocalGeneration: 1,
                              expectedRemoteHead: SyncV2RemoteHead(snapshotID: graph.headSnapshotID, generation: 2),
                              binding: SealedCommand.Binding(accountFence: productionBinding.accountFence, accountId: productionBinding.accountID,
                                                             protocolEpoch: 2, serverInstanceId: productionBinding.serverInstanceID))
    }
}

actor PriorityOperationPlanner: SyncV2CommandPlanner {
    let command: SealedCommand
    var acknowledged = false
    init(command: SealedCommand) {
        self.command = command
    }

    func nextCommand(workID _: WorkID) -> SyncV2CommandPlan {
        acknowledged ? .idle : .command(command)
    }

    func markSending(_ operation: SyncV2RemoteOperation, workID _: WorkID) -> SyncV2RemoteOperation {
        operation
    }

    func recordFailure(operation _: SyncV2RemoteOperation, workID _: WorkID, disposition: SyncV2CommandFailureDisposition) {
        if case .requeue = disposition {} else {
            Issue.record("Incomplete history discarded an operation")
        }
    }

    func acknowledgeCommand(_: SyncV2ReceiptReadback, command _: SealedCommand, verifiedInboxID _: UUID?) {
        acknowledged = true
    }

    func acknowledgeUpload(_: SyncV2UploadCompletion) {}
}
