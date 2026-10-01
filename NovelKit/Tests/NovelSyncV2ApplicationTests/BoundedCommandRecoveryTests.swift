import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Bounded legacy command recovery")
struct BoundedCommandRecoveryTests {
    @Test(arguments: [false, true], [false, true])
    func deterministicFailureDoesNotLoop(legacy: Bool, foundationError: Bool) async throws {
        let config = try TestRuntimeConfiguration()
        let workID = WorkID(UUID())
        let seed = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        _ = try await seed.checkpoint(V2CheckpointRequest(
            workID: workID, document: applicationTestDocument(), documentCreatedAt: applicationTestCreatedAt,
            expectedGeneration: 0, reason: .explicit
        ), scope: productionScope)
        let scope = TestScopeResolver(vault: config.vault, store: seed)
        let planner = ProductionSyncV2Planner(store: seed, scope: scope)
        guard case let .command(command) = try await planner.nextCommand(workID: workID) else {
            Issue.record("expected initial createWork"); return
        }
        if legacy {
            try await seed.quarantine(commandID: command.commandId, scope: productionScope, reason: "unexpected")
            try await seed.prepareLegacyRecoveryApplicationFixture()
        }
        await seed.close()
        await config.remote.setCommandHandler { _ in
            if foundationError {
                throw NSError(domain: "synthetic-encoding-failure", code: 1)
            }
            throw SyncV2Failure.fatal(.unexpected)
        }
        for _ in 0 ..< 3 {
            let app = try await SnapshotSyncV2Runtime.makeApplicationForTesting(mode: .test(config), resumeOnLaunch: false)
            for reason: SyncV2WakeReason in [.launch, .foreground, .networkRecovery, .systemWake] {
                try await app.wake(reason: reason)
                try await eventually { await app.lanes[workID]?.workerTask == nil }
                #expect(await config.remote.recordedOperations().count == 1)
                #expect(await app.lanes[workID]?.retryTask == nil)
            }
        }
        let app = try await SnapshotSyncV2Runtime.makeApplicationForTesting(mode: .test(config), resumeOnLaunch: false)
        for expected in 2 ... 3 {
            _ = try await app.synchronize(workID: workID)
            try await eventually { await app.lanes[workID]?.workerTask == nil }
            #expect(await config.remote.recordedOperations().count == expected)
        }
        let calls = await config.remote.recordedOperations()
        #expect(calls.allSatisfy { sealedCommand($0)?.command.canonicalBytes == command.canonicalBytes })
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .openExisting)
        #expect(try await store.quarantinedCommandReason(workID: workID, scope: productionScope) == "unexpected")
        #expect(try await store.query("SELECT COUNT(*) FROM legacy_command_recovery WHERE consumed=0").first?[0].int64 == 0)
        await store.close()
    }

    @Test(arguments: [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet, .cancelled], [false, true])
    func workerRequeuesRawTransportErrors(code: URLError.Code, foundationError: Bool) async throws {
        let config = try TestRuntimeConfiguration()
        let workID = WorkID(UUID())
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        _ = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: applicationTestDocument(), documentCreatedAt: applicationTestCreatedAt,
            expectedGeneration: 0, reason: .explicit
        ), scope: productionScope)
        await config.remote.setCommandHandler { _ in
            if foundationError {
                throw NSError(domain: NSURLErrorDomain, code: code.rawValue)
            }
            throw URLError(code)
        }
        let app = try await SnapshotSyncV2Runtime.makeApplicationForTesting(mode: .test(config), resumeOnLaunch: false)
        try await app.wake(reason: .launch)
        try await eventually { await app.lanes[workID]?.workerTask == nil }
        await app.cancelRetry(for: workID)
        let expected: SyncV2Failure = switch code {
        case .notConnectedToInternet, .networkConnectionLost: .offline
        case .cancelled: .retryable(.lostResponse)
        default: .retryable(.serverUnavailable)
        }
        #expect(await app.uiState(workID: workID)?.lastFailure == expected)
        #expect(try await store.quarantinedCommandReason(workID: workID, scope: productionScope) == nil)
        let pending = try await store.pendingSealedCommands(scope: productionScope, workID: workID)
        #expect(pending.count == 1)
        #expect(pending.first?.lifecycle == .sealed)
        #expect(await config.remote.recordedOperations().count == 1)
        await store.close()
    }
}
