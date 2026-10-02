import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Suite("Snapshot Sync v2 stable progress")
struct WorkerProgressTests {
    @Test("completion waits for the worker to drain", arguments: [false, true], [false, true])
    func completionWaitsForIdle(noChanges: Bool, editDuringSync: Bool) async throws {
        let state = InMemorySyncV2RuntimeState(account: TestAccount(accountID: "account", accountFence: "fence"))
        let planner = CompletionReadPlanner(base: state)
        let remote = ApplicationTestRemote([noChanges ? .noChanges() : .applied(), .applied()])
        let app = try SyncV2Application(
            mode: .test(TestRuntimeConfiguration()),
            composition: SyncV2RuntimeComposition(identity: .test, kernel: state, planner: planner,
                                                  remote: remote, gate: InMemorySyncV2DocumentGate(), library: state)
        )
        let workID = WorkID(UUID())
        let document = applicationTestDocument()
        _ = try await app.checkpoint(workID: workID, document: document, reason: .explicit,
                                     documentCreatedAt: applicationTestCreatedAt)
        try await eventually { await planner.isFirstReadSuspended() }
        let beforeSave = await app.uiState(workID: workID)
        if case .syncing = beforeSave?.remoteProgress {} else {
            Issue.record("An intermediate receipt must not show completion")
        }
        var updated = document
        if editDuringSync {
            updated.title = "更新した作品名"
        }
        _ = try await app.checkpoint(workID: workID, document: updated, reason: .explicit,
                                     documentCreatedAt: applicationTestCreatedAt)
        let afterSave = await app.uiState(workID: workID)
        if case .syncing = afterSave?.remoteProgress {} else {
            Issue.record("A concurrent save must retain active sync progress")
        }
        await planner.releaseFirstRead()
        try await eventually { await app.lanes[workID]?.workerTask == nil }
        #expect(await app.uiState(workID: workID)?.remoteProgress == .noChanges)
        #expect(await remote.recordedOperations().count == (editDuringSync ? 2 : 1))
    }
}

actor CompletionReadPlanner: SyncV2CommandPlanner {
    private let base: InMemorySyncV2RuntimeState
    private var receiptAcknowledged = false
    private var didPause = false
    private var firstReadSuspended = false
    private var firstReadContinuation: CheckedContinuation<Void, Never>?

    init(base: InMemorySyncV2RuntimeState) {
        self.base = base
    }

    func nextCommand(workID: WorkID) async throws -> SyncV2CommandPlan {
        if receiptAcknowledged, !didPause {
            didPause = true
            firstReadSuspended = true
            await withCheckedContinuation { firstReadContinuation = $0 }
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
        receiptAcknowledged = true
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
