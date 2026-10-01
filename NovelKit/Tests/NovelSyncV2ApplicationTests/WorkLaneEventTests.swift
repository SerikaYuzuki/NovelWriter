import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Suite("Work lane projection and push boundaries")
struct WorkLaneEventTests {
    @Test("gate version is durable even when the presentation is stale")
    func gateUsesDurableVersion() async throws {
        let kernel = InMemorySyncV2RuntimeState(account: TestAccount(accountID: "account", accountFence: "fence"))
        let app = try applicationTestApp(state: kernel, remote: ApplicationTestRemote([.failure(.offline)]))
        let workID = WorkID(UUID())
        let checkpoint = try await kernel.checkpoint(SyncV2CheckpointCapture(
            workID: workID, document: applicationTestDocument(), documentCreatedAt: applicationTestCreatedAt,
            expectedGeneration: 0, reason: .explicit
        ))
        // No open/checkpoint projection has run in the application, just as
        // after a durable acknowledgement wins a race with its UI projection.
        #expect(await app.uiState(workID: workID) == nil)
        let session = await app.beginSession(workID: workID)
        let token = try await app.documentGateToken(for: session)
        #expect(token.expectedLocalVersion.generation == checkpoint.generation)
        #expect(token.expectedLocalVersion.snapshotID == checkpoint.snapshotID)
    }

    @Test("subscribers receive each work and the adoption signal without polling")
    func adoptionAndWorkEvents() async throws {
        let kernel = InMemorySyncV2RuntimeState(account: TestAccount(accountID: "account", accountFence: "fence"))
        let app = try applicationTestApp(state: kernel, remote: ApplicationTestRemote([.failure(.offline)]))
        let first = WorkID(UUID())
        let second = WorkID(UUID())
        let inbox = UUID()
        let firstStream = await app.stateChanges(for: first, until: .now.advanced(by: .seconds(2)))
        let secondStream = await app.stateChanges(for: second, until: .now.advanced(by: .seconds(2)))
        var firstEvents = firstStream.makeAsyncIterator()
        var secondEvents = secondStream.makeAsyncIterator()
        _ = await firstEvents.next()
        _ = await secondEvents.next()
        _ = await app.setState(workID: first, localDurability: .unsaved, remoteProgress: .pending, result: .queued)
        _ = await app.setState(workID: second, localDurability: .unsaved,
                               remoteProgress: .readyForSafeAdoption(inboxID: inbox), result: .adoptionPending)
        guard case let .stateChanged(firstID, firstState) = await firstEvents.next(),
              case let .stateChanged(secondID, secondState) = await secondEvents.next(),
              case let .adoptionAvailable(adoptionID) = await secondEvents.next() else {
            Issue.record("Expected work projections followed by the adoption signal")
            return
        }
        #expect(firstID == first && firstState.workID == first)
        #expect(secondID == second && secondState.workID == second)
        #expect(adoptionID == second)
    }

    @Test("a deadline finishes an otherwise silent subscription")
    func subscriptionDeadline() async throws {
        let kernel = InMemorySyncV2RuntimeState(account: nil)
        let app = try applicationTestApp(state: kernel, remote: ApplicationTestRemote([.failure(.offline)]))
        let stream = await app.stateChanges(until: .now)
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count <= 1)
        try await eventually { await app.stateChangeContinuations.isEmpty }
    }
}
