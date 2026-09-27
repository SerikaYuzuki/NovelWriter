import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Suite("Snapshot Sync v2 checkpoint worker")
struct CheckpointWorkerTests {
    @Test("checkpoint is locally durable before a blocked transport completes")
    func checkpointIsLocalFirst() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.suspendThenFailure(.offline)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())

        let result = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )

        #expect(result.typedResult == .checkpointed)
        #expect(result.state.remoteProgress == .pending)
        #expect(result.state.japaneseLabel == "同期待ち")
        #expect(try await state.open(workID: workID).generation == 1)
        await remote.resumeSuspended()
    }

    @Test("offline is typed while the locally saved manuscript remains openable")
    func offlinePreservesLocalWork() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.failure(.offline)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())
        let document = applicationTestDocument()

        _ = try await app.checkpoint(
            workID: workID,
            document: document,
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually {
            await app.uiState(workID: workID)?.lastFailure == .offline
        }

        #expect(try await app.open(workID: workID).document == document)
        #expect(await app.uiState(workID: workID)?.japaneseLabel == "端末に保存済み・通信待ち")
    }

    @Test("explicit sync with no intent is a successful noChanges")
    func noOpIsSuccess() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.applied()])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }
        let result = try await app.synchronize(workID: workID)

        #expect(result.typedResult == .noChanges)
        #expect(result.state.remoteProgress == .noChanges)
        #expect(result.state.japaneseLabel == "同期済み")
    }

    @Test("restart replays the exact previously sealed command bytes")
    func restartReplaysExactBytes() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let firstRemote = ApplicationTestRemote([.failure(.offline)])
        let first = try applicationTestApp(state: state, remote: firstRemote)
        let workID = WorkID(UUID())

        _ = try await first.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually { await firstRemote.recordedOperations().count == 1 }
        let firstOperation = try #require(await firstRemote.recordedOperations().first)
        guard case let .command(firstCommand) = firstOperation else {
            Issue.record("expected a command")
            return
        }

        let secondRemote = ApplicationTestRemote([.applied()])
        let second = try applicationTestApp(state: state, remote: secondRemote)
        _ = try await second.open(workID: workID)
        try await eventually { await secondRemote.recordedOperations().count == 1 }
        let secondOperation = try #require(await secondRemote.recordedOperations().first)
        guard case let .command(secondCommand) = secondOperation else {
            Issue.record("expected a command")
            return
        }

        #expect(secondCommand.command.commandId == firstCommand.command.commandId)
        #expect(secondCommand.command.canonicalBytes == firstCommand.command.canonicalBytes)
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }
    }

    @Test("a newer edit survives acknowledgement of the older sealed intent")
    func newerIntentSurvivesOlderAcknowledgement() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([
            .suspendThenFailure(.retryable(.lostResponse)),
            .applied(),
            .applied()
        ])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())
        let documentID = UUID()

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(id: documentID, body: "first"),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually { await remote.recordedOperations().count == 1 }
        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(id: documentID, body: "second"),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        await remote.resumeSuspended()
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }

        let operations = await remote.recordedOperations()
        #expect(operations.count == 3)
        let bytes = operations.compactMap { operation -> Data? in
            guard case let .command(command) = operation else { return nil }
            return command.command.canonicalBytes
        }
        #expect(bytes.count == 3)
        #expect(bytes[0] == bytes[1])
        #expect(bytes[1] != bytes[2])
        #expect(
            try await state.open(workID: workID)
                .document?.chapters[0].episodes[0].content == "second"
        )
    }

    @Test("immutable document creation anchor cannot be reconstructed")
    func creationAnchorIsImmutable() async throws {
        let state = InMemorySyncV2RuntimeState()
        let remote = ApplicationTestRemote([.failure(.authenticationRequired)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())
        let documentID = UUID()

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(id: documentID, body: "first"),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        await #expect(throws: SyncV2Failure.fatal(.invalidLocalState)) {
            try await app.checkpoint(
                workID: workID,
                document: applicationTestDocument(id: documentID, body: "second"),
                reason: .explicit,
                documentCreatedAt: applicationTestCreatedAt.addingTimeInterval(1)
            )
        }
        #expect(
            try await state.open(workID: workID)
                .document?.chapters[0].episodes[0].content == "first"
        )
    }

    @Test(
        "typed worker failures remain distinguishable",
        arguments: [
            SyncV2Failure.authenticationRequired,
            SyncV2Failure.accountFenceChanged,
            SyncV2Failure.quarantined(.differentAccount),
            SyncV2Failure.retryable(.rateLimited),
            SyncV2Failure.fatal(.unexpected)
        ]
    )
    func typedFailures(failure: SyncV2Failure) async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.failure(failure)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually {
            await app.uiState(workID: workID)?.lastFailure == failure
        }
        #expect(await app.uiState(workID: workID)?.lastTypedResult == .failure(failure))
    }
}
