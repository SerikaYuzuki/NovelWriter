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

    @Test("a stale transition lease cannot resume a newer remote lane")
    func accountTransitionSuspensionIsOwnerScoped() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.failure(.offline)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())
        let first = await app.beginAccountTransitionRemoteSuspension()
        let second = await app.beginAccountTransitionRemoteSuspension()

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(await remote.recordedOperations().isEmpty)

        #expect(await app.endAccountTransitionRemoteSuspension(first, resume: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await remote.recordedOperations().isEmpty)

        #expect(await app.endAccountTransitionRemoteSuspension(second, resume: false))
        try await app.resumePending()
        try await eventually { await remote.recordedOperations().count == 1 }
    }

    @Test("account transition fails closed without an active suspension owner")
    func accountTransitionRequiresSuspensionOwner() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let app = try applicationTestApp(
            state: state,
            remote: ApplicationTestRemote([.failure(.offline)])
        )
        let staleToken = SyncV2AccountTransitionRemoteSuspensionToken()
        await #expect(throws: SyncV2ApplicationError.remoteSchedulingSuspensionRequired) {
            try await app.transitionAccountScopes(
                from: SyncV2AccountScopeBinding(
                    accountID: "account",
                    accountFence: "fence",
                    serverInstanceID: "test-server"
                ),
                to: nil,
                suspensionToken: staleToken
            )
        }
    }

    @Test("a late non-cooperative response cannot clear a newer worker slot")
    func lateRemoteCompletionCannotCrossWorkerOwner() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = NonCooperativeRemote()
        let planner = CountingPlanner(base: state)
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
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually { await remote.recordedOperations().count == 1 }

        let oldOwner = await app.workerOwners[workID]
        #expect(oldOwner != nil)
        let suspension = await app.beginAccountTransitionRemoteSuspension()
        #expect(await app.workerOwners[workID] == nil)
        #expect(await app.endAccountTransitionRemoteSuspension(suspension, resume: false))
        let pendingWorkIDs = try await (state as any SyncV2CommandPlanner).pendingWorkIDs()
        #expect(pendingWorkIDs.contains(workID))
        try await app.resumePending()
        #expect(await app.workerOwners[workID] != nil)
        try await eventually { await remote.recordedOperations().count == 2 }

        let newOwner = await app.workerOwners[workID]
        #expect(newOwner != nil)
        #expect(newOwner != oldOwner)
        // The first task is still awaiting the remote. Its continuation is
        // released only after the replacement worker has claimed the slot.
        await remote.releaseNext(result: .applied)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await planner.acknowledgeCount() == 0)
        #expect(await planner.failureCount() == 0)
        #expect(await state.pendingIntentCount(workID: workID) == 1)

        // Only the replacement worker may apply the exact response. The old
        // response is otherwise a valid-looking receipt, so this assertion
        // exercises the owner boundary rather than receipt validation.
        await remote.releaseNext(result: .applied)
        try await eventually { await app.workerOwners[workID] == nil }
        #expect(await remote.recordedOperations().count == 2)
        #expect(await planner.acknowledgeCount() == 1)
        #expect(await planner.failureCount() == 0)
        #expect(await state.pendingIntentCount(workID: workID) == 0)
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

private actor NonCooperativeRemote: SyncV2RemoteClient {
    private struct Pending {
        let operation: SyncV2RemoteOperation
        let continuation: CheckedContinuation<SyncV2RemoteExecution, Error>
    }

    private var operations: [SyncV2RemoteOperation] = []
    private var pending: [Pending] = []

    func execute(
        _ operation: SyncV2RemoteOperation
    ) async throws -> SyncV2RemoteExecution {
        operations.append(operation)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(operation: operation, continuation: continuation))
        }
    }

    func recordedOperations() -> [SyncV2RemoteOperation] {
        operations
    }

    func releaseAll() {
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.continuation.resume(throwing: SyncV2Failure.offline) }
    }

    func releaseNext(result: SyncV2RemoteResult) {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        switch result {
        case .applied:
            next.continuation.resume(returning: execution(for: next.operation, result: .applied))
        case .noChanges:
            next.continuation.resume(returning: execution(for: next.operation, result: .noChanges))
        case .conflictPending:
            next.continuation.resume(returning: execution(for: next.operation, result: .conflictPending))
        }
    }

    private func execution(
        for operation: SyncV2RemoteOperation,
        result: SyncV2RemoteResult
    ) -> SyncV2RemoteExecution {
        switch operation {
        case let .command(sealed):
            .command(
                receipt: SyncV2ReceiptReadback(
                    commandID: sealed.command.commandId,
                    requestDigest: sealed.command.requestDigest,
                    responseStatus: 200,
                    canonicalResponse: Data("{}".utf8),
                    predicates: SyncV2ReadBackPredicates(
                        accountMatched: true,
                        commandDigestMatched: true,
                        resourceMatched: true,
                        headMatched: true,
                        stateMatched: true
                    ),
                    result: result
                ),
                remoteInbox: nil
            )
        case let .upload(upload):
            .upload(
                SyncV2UploadCompletion(
                    transferID: upload.transferID,
                    uploadID: upload.uploadID,
                    objectID: upload.objectID,
                    acknowledgedByteCount: upload.exactBytes.count
                )
            )
        }
    }
}

private actor CountingPlanner: SyncV2CommandPlanner {
    private let base: InMemorySyncV2RuntimeState
    private var acknowledgements = 0
    private var failures = 0

    init(base: InMemorySyncV2RuntimeState) {
        self.base = base
    }

    func nextCommand(workID: WorkID) async throws -> SyncV2CommandPlan {
        try await base.nextCommand(workID: workID)
    }

    func pendingWorkIDs() async throws -> [WorkID] {
        try await (base as any SyncV2CommandPlanner).pendingWorkIDs()
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
        failures += 1
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
        acknowledgements += 1
        try await base.acknowledgeCommand(
            receipt,
            command: command,
            verifiedInboxID: verifiedInboxID
        )
    }

    func acknowledgeUpload(_ completion: SyncV2UploadCompletion) async throws {
        try await base.acknowledgeUpload(completion)
    }

    func acknowledgeCount() -> Int {
        acknowledgements
    }

    func failureCount() -> Int {
        failures
    }
}
