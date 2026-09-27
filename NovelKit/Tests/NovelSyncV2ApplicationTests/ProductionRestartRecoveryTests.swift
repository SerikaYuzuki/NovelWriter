import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

@Suite("Snapshot Sync v2 production restart recovery")
struct ProductionRestartRecoveryTests {
    @Test("restart restores one durable conflict and does not wake the network")
    func restartRestoresConflictWithoutNetwork() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        let first = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await first.open(workID: fixture.workID)
        let firstLibrary = try await first.library()
        #expect(firstLibrary.items.count(where: { $0.conflict != nil }) == 1)
        #expect(await first.uiState(workID: fixture.workID)?.remoteProgress == .needsChoice)
        let before = await configuration.remote.recordedOperations().count

        let restarted = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await restarted.open(workID: fixture.workID)
        let after = await configuration.remote.recordedOperations().count
        #expect(after == before)
        #expect(await restarted.uiState(workID: fixture.workID)?.remoteProgress == .needsChoice)
        #expect(await restarted.uiState(workID: fixture.workID)?.lastFailure == nil)
    }
}
