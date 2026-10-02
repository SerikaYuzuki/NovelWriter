import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

@Suite("D-103 durable leaf promotion")
struct LeafPromotionTests {
    @Test("autosaves do not call any remote command; manual and lifecycle saves publish latest only", arguments: [
        SyncV2CheckpointReason.explicit, .navigation, .close, .migration
    ])
    func protectingCheckpoint(reason: SyncV2CheckpointReason) async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("first")
        let latest = try await fixture.edit("latest")
        #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
        #expect(try await fixture.store.pendingIntents(scope: productionScope, workID: fixture.workID).isEmpty)
        #expect(await fixture.app.uiState(workID: fixture.workID)?.remoteProgress == .pending)
        _ = try await fixture.app.checkpoint(workID: fixture.workID, document: latest, reason: reason,
                                             documentCreatedAt: applicationTestCreatedAt)
        try await fixture.assertOnePublication(expected: latest)
        await fixture.close()
    }

    @Test("explicit sync, reopening and launch recover the latest unpublished bytes", arguments: ["sync", "open", "launch"])
    func recover(trigger: String) async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("earlier local leaf")
        let latest = try await fixture.edit("latest local leaf")
        await fixture.app.cancelLeafPromotion(workID: fixture.workID)
        switch trigger {
        case "sync": _ = try await fixture.app.synchronize(workID: fixture.workID)
        case "open": _ = try await fixture.app.openLocal(workID: fixture.workID)
        default:
            // Recreate the real SQLite composition without opening the work.
            let restarted = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(fixture.configuration))
            try await fixture.assertOnePublication(expected: latest)
            await restarted.cancelWorker(for: fixture.workID)
        }
        try await fixture.assertOnePublication(expected: latest)
        await fixture.close()
    }

    @Test("idle promotion is 60 seconds after the last changed checkpoint")
    func idle() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("first")
        try await leafEventually { fixture.clock.waitingCount == 1 }
        fixture.clock.advance(50)
        let latest = try await fixture.edit("last edit")
        try await leafEventually { fixture.clock.waitingCount == 1 }
        fixture.clock.advance(59)
        #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
        fixture.clock.advance(1)
        try await fixture.assertOnePublication(expected: latest)
        await fixture.close()
    }

    @Test("continuous writing promotes latest content after at most five minutes")
    func maximumInterval() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        var latest = try await fixture.edit("start")
        for index in 1 ... 5 {
            try await leafEventually { fixture.clock.waitingCount == 1 }
            fixture.clock.advance(50)
            latest = try await fixture.edit("continuous edit \(index)")
        }
        try await leafEventually { fixture.clock.waitingCount == 1 }
        fixture.clock.advance(49)
        #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
        fixture.clock.advance(1)
        try await fixture.assertOnePublication(expected: latest)
        await fixture.close()
    }
}

extension LeafPromotionTests {
    @Test("periodic worker wakes do not promote a newly edited leaf")
    func periodicWakeIsNotPromotion() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let latest = try await fixture.edit("waiting for idle")
        for _ in 0 ..< 4 {
            try await fixture.app.resumePending()
        }
        #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
        #expect(try await fixture.store.hasUnpromotedLeaf(workID: fixture.workID, scope: productionScope))
        try await leafEventually { fixture.clock.waitingCount == 1 }
        fixture.clock.advance(60)
        try await fixture.assertOnePublication(expected: latest)
        await fixture.close()
    }

    @Test("promotion never enters the editor gate while composition is marked")
    func markedTextGateIsUntouched() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let durable = try await fixture.edit("last committed text")
        let session = await fixture.app.beginSession(workID: fixture.workID)
        await fixture.gate.setUnsafe(true, workID: fixture.workID)
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await fixture.app.documentGateToken(for: session)
        }
        try await leafEventually { fixture.clock.waitingCount == 1 }
        fixture.clock.advance(60)
        try await fixture.assertOnePublication(expected: durable)
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await fixture.app.documentGateToken(for: session)
        }
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document == durable)
        await fixture.close()
    }

    @Test("an account transition during the idle delay keeps the leaf parked")
    func timerCannotPublishParkedAccount() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let durable = try await fixture.edit("private leaf")
        try await leafEventually { fixture.clock.waitingCount == 1 }
        try await fixture.app.parkAccountScope(workID: fixture.workID, binding: SyncV2AccountScopeBinding(
            accountID: productionBinding.accountID, accountFence: productionBinding.accountFence,
            serverInstanceID: productionBinding.serverInstanceID
        ))
        fixture.clock.advance(60)
        try await leafEventually { await fixture.app.lanes[fixture.workID]?.promotionTask == nil }
        #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
        #expect(try await fixture.store.open(workID: fixture.workID, scope: .parked).document == durable)
        #expect(try await fixture.store.pendingIntents(scope: .unbound).isEmpty)
        await fixture.close()
    }

    @Test("restore protects a leaf and still registers its required closure and publishes")
    func restoreFromLeaf() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("retained before restore")
        let before = try await fixture.store.workSummary(workID: fixture.workID, scope: productionScope)
        _ = try await fixture.app.restore(workID: fixture.workID, snapshotID: fixture.baseline)
        try await leafEventually {
            try await fixture.store.allSealedCommands(scope: productionScope, workID: fixture.workID)
                .contains { $0.commandKind == "restore" && $0.lifecycle == .completed }
        }
        let commands = try await fixture.store.allSealedCommands(scope: productionScope, workID: fixture.workID)
        #expect(commands.count(where: { $0.commandKind == "registerSnapshot" }) == 2)
        #expect(commands.count(where: { $0.commandKind == "restore" }) == 1)
        #expect(try await fixture.store.history(workID: fixture.workID, scope: productionScope)
            .contains { $0.snapshotID == before.currentSnapshotID && $0.pinned })
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document == fixture.document)
        await fixture.close()
    }
}
