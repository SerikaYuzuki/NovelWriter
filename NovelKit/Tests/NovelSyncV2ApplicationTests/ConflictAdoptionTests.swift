import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Suite("Snapshot Sync v2 conflict and safe adoption")
struct ConflictAdoptionTests {
    @Test(
        "three choices durably prepare their closed command kind",
        arguments: [
            (SyncV2ConflictChoice.useDevice, SyncV2RemoteOperationKind.resolveDevice),
            (SyncV2ConflictChoice.useServer, SyncV2RemoteOperationKind.resolveServer),
            (SyncV2ConflictChoice.keepBoth, SyncV2RemoteOperationKind.cloneWork)
        ]
    )
    func choicesPrepareDurableCommand(
        choice: SyncV2ConflictChoice,
        expectedKind: SyncV2RemoteOperationKind
    ) async throws {
        let fixture = try await ConflictFixture.make(
            resolutionChoice: choice,
            resolutionReply: .applied()
        )

        _ = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: choice)
        )
        if choice == .keepBoth {
            try await fixture.app.resumePending()
        }
        try await eventually {
            await fixture.remote.recordedOperations().count == 2
        }

        let operations = await fixture.remote.recordedOperations()
        #expect(commandKind(operations[1]) == expectedKind)
        #expect(await fixture.state.pendingIntentCount(workID: fixture.workID) == 0)
        if choice != .useServer {
            try await eventually {
                await fixture.app.uiState(workID: fixture.workID)?.conflict == nil
            }
        }
    }

    @Test("use device creates a two-parent decision snapshot")
    func useDeviceCreatesDecisionSnapshot() async throws {
        let fixture = try await ConflictFixture.make(
            resolutionChoice: .useDevice,
            resolutionReply: .applied()
        )
        let before = try await fixture.state.open(workID: fixture.workID)

        _ = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: .useDevice)
        )
        try await eventually {
            await fixture.state.pendingIntentCount(workID: fixture.workID) == 0
        }
        let after = try await fixture.state.open(workID: fixture.workID)

        #expect(after.generation == before.generation + 1)
        #expect(after.snapshotID != before.snapshotID)
    }

    @Test("keep-both installs and returns the clone before transport completes")
    func keepBothSwitchIsLocalFirst() async throws {
        let fixture = try await ConflictFixture.make(
            resolutionChoice: .keepBoth,
            resolutionReply: .suspendThenFailure(.offline)
        )
        let sourceBefore = try await fixture.state.open(workID: fixture.workID)

        let result = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: .keepBoth)
        )
        let clone = try #require(result.openedWork)
        #expect(clone.workID != fixture.workID)
        #expect(clone.document?.id != sourceBefore.document?.id)
        #expect(clone.document?.title == sourceBefore.document?.title)
        #expect(try await fixture.state.open(workID: clone.workID).document?.id == clone.document?.id)
        #expect(await fixture.remote.recordedOperations().count == 1)

        // A transport that never returns cannot prevent editing the clone.
        _ = try await fixture.app.checkpoint(
            workID: clone.workID,
            document: applicationTestDocument(
                id: clone.document?.id ?? UUID(),
                title: "複製側の追記"
            ),
            reason: .autosave,
            documentCreatedAt: clone.documentCreatedAt
        )
        #expect(try await fixture.state.open(workID: fixture.workID).document?.title == sourceBefore.document?.title)
        #expect(try await fixture.state.open(workID: clone.workID).document?.title == "複製側の追記")
        try await fixture.app.resumePending()
        try await eventually { await fixture.remote.recordedOperations().count == 2 }
        await fixture.remote.resumeSuspended()
    }

    @Test("keep-both reserves clone publishing until source clone is acknowledged")
    func keepBothClonePublishesAfterSourceAck() async throws {
        let fixture = try await ConflictFixture.make(
            resolutionChoice: .keepBoth,
            resolutionReply: .applied()
        )

        let result = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: .keepBoth)
        )
        let clone = try #require(result.openedWork)
        _ = try await fixture.app.checkpoint(
            workID: clone.workID,
            document: applicationTestDocument(
                id: clone.document?.id ?? UUID(),
                title: "複製側の先行編集"
            ),
            reason: .autosave,
            documentCreatedAt: clone.documentCreatedAt
        )

        // Editing the reserved clone must never race the source cloneWork.
        #expect(await fixture.remote.recordedOperations().count == 1)
        try await fixture.app.resumePending()
        try await eventually {
            await fixture.remote.recordedOperations().count == 2
        }
        let afterSource = await fixture.remote.recordedOperations()
        #expect(commandKind(afterSource[1]) == .cloneWork)
        if case let .command(cloneCommand) = afterSource[1],
           let canonical = String(data: cloneCommand.command.canonicalBytes, encoding: .utf8) {
            #expect(canonical.contains(clone.workID.description))
        } else {
            Issue.record("cloneWork command was not recorded")
        }
        #expect(afterSource.count == 2)

        // The clone lane is unlocked by the source ACK, but is not implicitly
        // sent from inside that ACK.  A later wake sends the saved edit.
        try await fixture.app.resumePending()
        try await eventually {
            await fixture.remote.recordedOperations().count == 3
        }
        let afterClone = await fixture.remote.recordedOperations()
        #expect(commandKind(afterClone[2]) == .publish)
        #expect(try await fixture.state.open(workID: clone.workID).document?.title == "複製側の先行編集")
    }

    @Test("use server stays pending until safe gated adoption")
    func useServerRequiresSafeAdoption() async throws {
        let fixture = try await ConflictFixture.makeForServerAdoption()

        _ = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: .useServer)
        )
        try await eventually {
            try await fixture.app.pendingAdoption(workID: fixture.workID) != nil
        }
        let pending = try #require(
            try await fixture.app.pendingAdoption(workID: fixture.workID)
        )
        let preAdoption = try await fixture.app.open(workID: fixture.workID)

        #expect(preAdoption.document?.title == "端末版")
        #expect(await fixture.app.uiState(workID: fixture.workID)?.conflict != nil)
        #expect(
            await fixture.app.uiState(workID: fixture.workID)?.remoteProgress ==
                .readyForSafeAdoption(inboxID: pending.inboxID)
        )

        let session = await fixture.app.beginSession(workID: fixture.workID)
        let token = try await fixture.app.documentGateToken(for: session)
        let adopted = try await fixture.app.applyStagedRemote(
            at: SafeAdoptionBoundary(
                workID: fixture.workID,
                inboxID: pending.inboxID,
                session: session,
                gate: token
            )
        )

        #expect(adopted.document?.title == "サーバー版")
        #expect(try await fixture.app.pendingAdoption(workID: fixture.workID) == nil)
        #expect(await fixture.app.uiState(workID: fixture.workID)?.conflict == nil)
    }

    @Test("a newer local edit blocks adoption and keeps verified inbox pending")
    func newerEditBlocksServerAdoption() async throws {
        let fixture = try await ConflictFixture.makeForServerAdoption(
            trailingReply: .suspendThenFailure(.offline)
        )
        _ = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: .useServer)
        )
        try await eventually {
            try await fixture.app.pendingAdoption(workID: fixture.workID) != nil
        }
        let pending = try #require(
            try await fixture.app.pendingAdoption(workID: fixture.workID)
        )

        _ = try await fixture.app.checkpoint(
            workID: fixture.workID,
            document: applicationTestDocument(
                id: fixture.documentID,
                title: "端末版の追記",
                body: "newer"
            ),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        let session = await fixture.app.beginSession(workID: fixture.workID)
        let token = try await fixture.app.documentGateToken(for: session)

        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await fixture.app.applyStagedRemote(
                at: SafeAdoptionBoundary(
                    workID: fixture.workID,
                    inboxID: pending.inboxID,
                    session: session,
                    gate: token
                )
            )
        }
        #expect(try await fixture.app.pendingAdoption(workID: fixture.workID) == pending)
        #expect(try await fixture.state.open(workID: fixture.workID).document?.title == "端末版の追記")
        await fixture.remote.resumeSuspended()
    }

    @Test("unsafe document gate refuses to issue an adoption proof")
    func unsafeGateIsRejected() async throws {
        let gate = InMemorySyncV2DocumentGate()
        let fixture = try await ConflictFixture.makeForServerAdoption(gate: gate)
        _ = try await fixture.app.resolveConflict(
            workID: fixture.workID,
            action: fixture.action(choice: .useServer)
        )
        try await eventually {
            try await fixture.app.pendingAdoption(workID: fixture.workID) != nil
        }

        await gate.setUnsafe(true, workID: fixture.workID)
        let session = await fixture.app.beginSession(workID: fixture.workID)
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await fixture.app.documentGateToken(for: session)
        }
    }
}

private struct ConflictFixture {
    let app: SyncV2Application
    let state: InMemorySyncV2RuntimeState
    let remote: ApplicationTestRemote
    let workID: WorkID
    let documentID: UUID
    let projection: SyncV2ConflictProjection
    let serverInbox: SyncV2RemoteInbox

    static func make(
        resolutionChoice: SyncV2ConflictChoice,
        resolutionReply: ApplicationTestRemote.Reply? = nil,
        adoptsServer: Bool = false,
        trailingReply: ApplicationTestRemote.Reply? = nil,
        gate: InMemorySyncV2DocumentGate = InMemorySyncV2DocumentGate()
    ) async throws -> ConflictFixture {
        _ = resolutionChoice
        let workID = WorkID(UUID())
        let documentID = UUID()
        let localDocument = applicationTestDocument(
            id: documentID,
            title: "端末版"
        )
        let local = try SnapshotCodec.encode(
            SnapshotModel(
                workId: workID,
                document: localDocument,
                documentCreatedAt: applicationTestCreatedAt
            ),
            parents: []
        )
        let serverInbox = try applicationTestInbox(
            workID: workID,
            document: applicationTestDocument(
                id: documentID,
                title: "サーバー版"
            ),
            currentSnapshotID: local.snapshotId,
            localGeneration: 1
        )
        let projection = SyncV2ConflictProjection(
            conflictID: UUID(),
            revision: 1,
            baseSnapshotID: nil,
            localSnapshotID: local.snapshotId,
            remoteSnapshotID: serverInbox.headSnapshotID,
            sourceGeneration: 1
        )
        let selectedReply: ApplicationTestRemote.Reply = adoptsServer
            ? .applied(inbox: serverInbox)
            : resolutionReply ?? .applied()
        var replies: [ApplicationTestRemote.Reply] = [
            .conflict(projection),
            selectedReply
        ]
        if let trailingReply {
            replies.append(trailingReply)
        }
        let remote = ApplicationTestRemote(replies)
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let app = try applicationTestApp(state: state, remote: remote, gate: gate)
        _ = try await app.checkpoint(
            workID: workID,
            document: localDocument,
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually {
            await app.uiState(workID: workID)?.remoteProgress == .needsChoice
        }
        return ConflictFixture(
            app: app,
            state: state,
            remote: remote,
            workID: workID,
            documentID: documentID,
            projection: projection,
            serverInbox: serverInbox
        )
    }

    static func makeForServerAdoption(
        trailingReply: ApplicationTestRemote.Reply? = nil,
        gate: InMemorySyncV2DocumentGate = InMemorySyncV2DocumentGate()
    ) async throws -> ConflictFixture {
        try await make(
            resolutionChoice: .useServer,
            adoptsServer: true,
            trailingReply: trailingReply,
            gate: gate
        )
    }

    func action(choice: SyncV2ConflictChoice) -> SyncV2ConflictAction {
        SyncV2ConflictAction(
            workID: workID,
            conflictID: projection.conflictID,
            revision: projection.revision,
            baseSnapshotID: projection.baseSnapshotID,
            localSnapshotID: projection.localSnapshotID,
            remoteSnapshotID: projection.remoteSnapshotID,
            sourceGeneration: projection.sourceGeneration,
            choice: choice
        )
    }
}
