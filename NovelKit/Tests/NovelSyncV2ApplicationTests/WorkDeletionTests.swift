import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Work deletion recovery")
struct WorkDeletionTests {
    @Test("offline deletion preserves bytes and restart retries before ordinary sync")
    func resumesDeletion() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        await #expect(throws: SyncV2Failure.offline) { try await app.deleteWork(workID: fixture.workID) }
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        #expect(try await store.workDeletion(workID: fixture.workID)?.completed == false)
        #expect(try await store.open(workID: fixture.workID, scope: productionScope).document?.title == "端末版")
        await #expect(throws: SyncV2ApplicationError.workDeletionPending) {
            try await app.openLocal(workID: fixture.workID)
        }
        await configuration.remote.setDeletionFailure(nil)
        let restarted = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        try await restarted.resumePending()
        for _ in 0 ..< 100 {
            if try await store.workDeletion(workID: fixture.workID)?.completed == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await restarted.deletedWorkIDs().contains(fixture.workID))
        #expect(try await restarted.library().items.isEmpty)
        #expect(await configuration.remote.recordedOperations().isEmpty)
        #expect(await configuration.remote.recordedDeletions() == [fixture.workID, fixture.workID])
    }
}
