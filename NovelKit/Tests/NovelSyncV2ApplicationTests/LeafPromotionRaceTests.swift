import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

extension LeafPromotionTests {
    @Test("a newer unpromoted leaf does not invalidate registration or publication of its stable parent")
    func editDuringStableTransfer() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        _ = try await fixture.edit("promoted version")
        #expect(try await fixture.store.promoteCurrentLeaf(workID: fixture.workID, scope: productionScope))
        let stableSummary = try await fixture.store.workSummary(workID: fixture.workID, scope: productionScope)
        let planner = ProductionSyncV2Planner(store: fixture.store, scope: TestScopeResolver(
            vault: fixture.configuration.vault, store: fixture.store
        ))
        var injected = false
        for _ in 0 ..< 50 {
            let plan = try await planner.nextCommand(workID: fixture.workID)
            if case .idle = plan {
                break
            }
            guard case let .command(command) = plan else {
                Issue.record("unexpected transfer plan")
                break
            }
            if command.commandKind == "registerSnapshot", !injected {
                _ = try await fixture.edit("newer unsent text")
                injected = true
            }
            let execution = try leafSuccessResponse(SyncV2SealedRemoteCommand(command: command))
            guard case let .command(receipt, _) = execution else { return }
            try await planner.acknowledgeCommand(receipt, command: command, verifiedInboxID: nil)
        }
        #expect(injected)
        let commands = try await fixture.store.allSealedCommands(scope: productionScope, workID: fixture.workID)
        let published = commands.filter { $0.commandKind == "publish" }
        #expect(published.count == 1)
        #expect(published.first?.sourceSnapshotID == stableSummary.currentSnapshotID)
        let current = try await fixture.store.open(workID: fixture.workID, scope: productionScope)
        #expect(current.document?.chapters[0].episodes[0].content == "newer unsent text")
        #expect(try await fixture.store.hasUnpromotedLeaf(workID: fixture.workID, scope: productionScope))
        #expect(try await fixture.store.pendingIntents(scope: productionScope, workID: fixture.workID).isEmpty)
        try await fixture.app.promoteCheckpoint(workID: fixture.workID)
        try await leafEventually {
            try await fixture.store.allSealedCommands(scope: productionScope, workID: fixture.workID)
                .count(where: { $0.commandKind == "publish" && $0.lifecycle == .completed }) == 2
        }
        await fixture.close()
    }

    @Test("remote advancement while leaves exist preserves conflict and all three choices", arguments: [
        SyncV2ConflictChoice.useDevice, .useServer, .keepBoth
    ])
    func remoteAdvancePreservesChoices(choice: SyncV2ConflictChoice) async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let document = try await fixture.edit("local unpublished branch")
        let local = try await fixture.store.workSummary(workID: fixture.workID, scope: productionScope)
        let localID = try #require(local.currentSnapshotID)
        var remoteDocument = document
        remoteDocument.title = "other device"
        let remote = try SnapshotCodec.encode(SnapshotModel(
            workId: fixture.workID, document: remoteDocument, documentCreatedAt: applicationTestCreatedAt
        ), parents: [fixture.baseline])
        let remoteHead = try SyncV2RemoteHead(snapshotID: remote.snapshotId, generation: 3)
        await fixture.configuration.remote.setHeadHandler { _ in remoteHead }
        await fixture.configuration.remote.setCommandHandler { command in
            if command.kind == .publish {
                return try leafConflictResponse(command, workID: fixture.workID, base: fixture.baseline,
                                                local: localID, remote: remote, head: remoteHead)
            }
            return try leafSuccessResponse(command)
        }
        #expect(try await fixture.app.checkForRemoteUpdates(workID: fixture.workID))
        try await leafEventually { await fixture.app.uiState(workID: fixture.workID)?.conflict != nil }
        let conflict = try #require(try await fixture.store.activeConflict(workID: fixture.workID, scope: productionScope))
        #expect(conflict.baseSnapshotID == fixture.baseline)
        #expect(conflict.localSnapshotID == localID)
        #expect(conflict.remoteSnapshotID == remote.snapshotId)
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document == document)
        let responseFixture = try ProductionConflictFixture(
            workID: fixture.workID, baseSnapshotID: fixture.baseline, localSnapshotID: localID,
            sourceGeneration: local.localGeneration, remote: remote,
            remoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 3)
        )
        await installProductionResponder(fixture.configuration.remote, fixture: responseFixture)
        _ = try await fixture.app.resolveConflict(workID: fixture.workID, action: SyncV2ConflictAction(
            workID: fixture.workID, conflictID: conflict.conflictID, revision: conflict.revision,
            baseSnapshotID: conflict.baseSnapshotID, localSnapshotID: conflict.localSnapshotID,
            remoteSnapshotID: conflict.remoteSnapshotID, sourceGeneration: conflict.sourceGeneration,
            choice: choice, inboxID: fixture.store.conflictInboxID(conflict)
        ))
        if choice == .keepBoth {
            try await fixture.app.resumePending()
        }
        let kind = choice == .useDevice ? "resolveDevice" : choice == .useServer ? "resolveServer" : "cloneWork"
        try await leafEventually {
            try await fixture.store.allSealedCommands(scope: productionScope, workID: fixture.workID)
                .contains { $0.commandKind == kind && $0.lifecycle == .completed }
        }
        #expect(await fixture.app.uiState(workID: fixture.workID)?.lastFailure == nil)
        if choice == .useServer {
            #expect(try await fixture.app.pendingAdoption(workID: fixture.workID) != nil)
            #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document == document)
        }
        await fixture.close()
    }
}

private func leafConflictResponse(
    _ command: SyncV2SealedRemoteCommand, workID: WorkID, base: SnapshotID,
    local: SnapshotID, remote: EncodedSnapshot, head: SyncV2RemoteHead
) throws -> SyncV2RemoteExecution {
    let storeHead = try V2RemoteHead(snapshotID: head.snapshotID, generation: head.generation)
    let response = try productionResponse(command: command.command, result: .conflictPending,
                                          head: storeHead, cloneHead: nil, status: 409)
    let object = try productionDictionary(response)
    let conflictID = try #require(UUID(uuidString: productionString(object, key: "conflictId")))
    let conflict = SyncV2ConflictProjection(conflictID: conflictID, revision: 1, baseSnapshotID: base,
                                            localSnapshotID: local, remoteSnapshotID: remote.snapshotId,
                                            sourceGeneration: command.command.sourceGeneration)
    let inbox = SyncV2RemoteInbox(inboxID: UUID(), workID: workID, headSnapshotID: remote.snapshotId,
                                  snapshots: [remote], expectedCurrentSnapshotID: local,
                                  expectedLocalGeneration: command.command.sourceGeneration, expectedRemoteHead: head)
    let envelope = try productionEnvelope(command: command.command, response: response, result: .conflictPending, status: 409)
    return .command(receipt: SyncV2ReceiptReadback(
        commandID: command.command.commandId, requestDigest: command.command.requestDigest,
        responseStatus: 409, canonicalResponse: envelope,
        predicates: SyncV2ReadBackPredicates(accountMatched: true, commandDigestMatched: true,
                                             resourceMatched: true, headMatched: true, stateMatched: true),
        result: .conflictPending, conflict: conflict, remoteHead: head
    ), remoteInbox: inbox)
}
