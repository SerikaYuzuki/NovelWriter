import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelWorkspace
import Testing

struct SnapshotComparisonIntegrationTests {
    @Test func cacheCoalescesAndScopeInvalidatesWithoutNetwork() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("changed body")
        let current = try #require(try await fixture.app.currentSnapshotID(workID: fixture.workID))
        let reads = await fixture.configuration.remote.recordedHeadReads().count
        async let first = fixture.app.snapshotDifference(workID: fixture.workID, before: fixture.baseline, after: current)
        async let second = fixture.app.snapshotDifference(workID: fixture.workID, before: fixture.baseline, after: current)
        let results = try await [first, second]
        #expect(results[0] == results[1])
        #expect(await fixture.app.snapshotDifferences.count == 1)
        #expect(await fixture.app.snapshotDifferenceFlights.isEmpty)
        #expect(await fixture.configuration.remote.recordedHeadReads().count == reads)
        await fixture.app.invalidateComparisonTestScope()
        #expect(await fixture.app.snapshotDifferences.isEmpty)
        await fixture.close()
    }

    @Test func unfetchedResultIsNotCached() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let absent = try SnapshotID(rawValue: String(repeating: "f", count: 64))
        let result = try await fixture.app.snapshotDifference(workID: fixture.workID, before: absent, after: fixture.baseline)
        #expect(result == .unfetched)
        #expect(await fixture.app.snapshotDifferences.isEmpty)
        await fixture.close()
    }

    @Test @MainActor func undoCallsExistingRestoreWithUnselectedSnapshot() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("chosen version")
        let selected = try #require(try await fixture.app.currentSnapshotID(workID: fixture.workID))
        var restored: [SnapshotID] = []
        let success = await ConflictCoordinator(application: fixture.app).undo(
            workID: fixture.workID, snapshotID: fixture.baseline,
            serverChoice: true, isCurrent: { true }, adopt: { false },
            restore: { snapshot in
                restored.append(snapshot)
                return await (try? fixture.app.restore(workID: fixture.workID, snapshotID: snapshot).typedResult) == .restored
            }
        )
        #expect(success)
        #expect(restored == [fixture.baseline])
        #expect(try await fixture.app.currentSnapshotID(workID: fixture.workID) != selected)
        await fixture.close()
    }

    @Test @MainActor func staleUndoDoesNotRestoreAnotherWork() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        var called = false
        let success = await ConflictCoordinator(application: fixture.app).undo(
            workID: fixture.workID, snapshotID: fixture.baseline,
            serverChoice: false, isCurrent: { false }, adopt: { false },
            restore: { _ in called = true; return true }
        )
        #expect(!success)
        #expect(!called)
        await fixture.close()
    }

    @Test func choiceGateRejectsSecondOperationAndAllowsFailureRetry() {
        var gate = SnapshotConflictChoiceGate()
        let first = gate.begin()
        let second = gate.begin()
        #expect(first)
        #expect(gate.isInFlight)
        #expect(!second)
        gate.retryAfterFailure()
        let retry = gate.begin()
        #expect(retry)
    }
}

private extension SyncV2Application {
    func invalidateComparisonTestScope() {
        historyScopeGeneration &+= 1
    }
}
