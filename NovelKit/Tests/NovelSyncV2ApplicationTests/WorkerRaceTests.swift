import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Suite("Snapshot Sync v2 worker races")
struct WorkerRaceTests {
    @Test("a wake arriving while the worker observes idle is not lost")
    func lostWakeupIsClosed() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let planner = IdleRacePlanner(base: state)
        let remote = ApplicationTestRemote([.applied()])
        let configuration = try TestRuntimeConfiguration()
        let app = try SyncV2Application(
            mode: .test(configuration),
            composition: SyncV2RuntimeComposition(
                identity: .test,
                kernel: state,
                planner: planner,
                remote: remote,
                gate: InMemorySyncV2DocumentGate(),
                library: state
            )
        )
        let workID = WorkID(UUID())

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually { await planner.isFirstReadSuspended() }
        let sync = try await app.synchronize(workID: workID)
        #expect(sync.typedResult == .queued)
        await planner.releaseFirstRead()

        try await eventually { await remote.recordedOperations().count == 1 }
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }
    }

    @Test("receipt mismatch is typed and cannot acknowledge the intent")
    func receiptMismatchIsFailClosed() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let app = try applicationTestApp(
            state: state,
            remote: MismatchedReceiptRemote()
        )
        let workID = WorkID(UUID())

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually {
            await app.uiState(workID: workID)?.lastFailure == .receiptMismatch
        }

        #expect(await state.pendingIntentCount(workID: workID) == 1)
        #expect(
            await app.uiState(workID: workID)?.remoteProgress == .receiptMismatch
        )
    }
}

private actor IdleRacePlanner: SyncV2CommandPlanner {
    private let base: InMemorySyncV2RuntimeState
    private var isFirst = true
    private var firstReadSuspended = false
    private var firstReadContinuation: CheckedContinuation<Void, Never>?

    init(base: InMemorySyncV2RuntimeState) {
        self.base = base
    }

    func nextCommand(workID: WorkID) async throws -> SyncV2CommandPlan {
        if isFirst {
            isFirst = false
            firstReadSuspended = true
            await withCheckedContinuation { firstReadContinuation = $0 }
            return .idle
        }
        return try await base.nextCommand(workID: workID)
    }

    func markSending(
        _ operation: SyncV2RemoteOperation,
        workID: WorkID
    ) async throws -> SyncV2RemoteOperation {
        try await base.markSending(operation, workID: workID)
    }

    func recordFailure(
        operation: SyncV2RemoteOperation,
        workID: WorkID,
        disposition: SyncV2CommandFailureDisposition
    ) async throws {
        try await base.recordFailure(
            operation: operation,
            workID: workID,
            disposition: disposition
        )
    }

    func acknowledgeCommand(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        verifiedInboxID: UUID?
    ) async throws {
        try await base.acknowledgeCommand(
            receipt,
            command: command,
            verifiedInboxID: verifiedInboxID
        )
    }

    func acknowledgeUpload(_ completion: SyncV2UploadCompletion) async throws {
        try await base.acknowledgeUpload(completion)
    }

    func isFirstReadSuspended() -> Bool {
        firstReadSuspended
    }

    func releaseFirstRead() {
        firstReadSuspended = false
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }
}

private actor MismatchedReceiptRemote: SyncV2RemoteClient {
    func execute(
        _ operation: SyncV2RemoteOperation
    ) throws -> SyncV2RemoteExecution {
        guard case let .command(command) = operation else {
            throw SyncV2Failure.receiptMismatch
        }
        return .command(
            receipt: SyncV2ReceiptReadback(
                commandID: UUID(),
                requestDigest: command.command.requestDigest,
                responseStatus: 200,
                canonicalResponse: Data("{}".utf8),
                predicates: SyncV2ReadBackPredicates(
                    accountMatched: true,
                    commandDigestMatched: true,
                    resourceMatched: true,
                    headMatched: true,
                    stateMatched: true
                ),
                result: .applied
            ),
            remoteInbox: nil
        )
    }
}
