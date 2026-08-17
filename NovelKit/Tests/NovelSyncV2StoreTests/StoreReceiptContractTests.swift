import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func receiptEnvelopeBindsStatusResultScopeDigestPredicatesAndHead() async throws {
    let root = temporaryStoreRoot("receipt-envelope")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "receipt"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    let validHead = try V2RemoteHead(
        snapshotID: checkpoint.snapshotID,
        generation: 1
    )
    let wrongHead = try V2RemoteHead(
        snapshotID: SnapshotID(rawValue: String(repeating: "b", count: 64)),
        generation: 1
    )
    let invalid = try invalidAcknowledgements(
        command: command,
        validHead: validHead,
        wrongHead: wrongHead
    )
    for acknowledgement in invalid {
        do {
            try await store.acknowledge(acknowledgement, scope: scopeA)
            Issue.record("unbound receipt envelope completed the command")
        } catch SyncV2StoreError.invalidAcknowledgement {}
    }

    #expect(try await store.receiptReadback(
        commandID: command.commandId,
        scope: scopeA
    ) == nil)
    #expect(try await store.pendingSealedCommands(scope: scopeA).map(\.commandID) == [
        command.commandId
    ])
    #expect(try await store.pendingIntents(scope: scopeA).map(\.sourceSnapshotID) == [
        checkpoint.snapshotID
    ])
    let beforeValid = try await store.open(workID: workID, scope: scopeA)
    #expect(beforeValid.summary.currentSnapshotID == checkpoint.snapshotID)
    #expect(beforeValid.summary.acknowledgedHeadGeneration == nil)
    #expect(try await store.historyCount(workID: workID, scope: scopeA) == 1)

    try await store.acknowledge(
        commandAcknowledgement(command, head: validHead),
        scope: scopeA
    )
    #expect(try await store.receiptReadback(
        commandID: command.commandId,
        scope: scopeA
    )?.predicates.allVerified == true)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
}

private func invalidAcknowledgements(
    command: SealedCommand,
    validHead: V2RemoteHead,
    wrongHead: V2RemoteHead
) throws -> [V2CommandAcknowledgement] {
    try [
        commandAcknowledgement(
            command,
            head: validHead,
            mutateEnvelope: { $0["originalResponseStatus"] = 500 }
        ),
        commandAcknowledgement(
            command,
            head: validHead,
            mutateResponse: { $0["result"] = "noChanges" }
        ),
        commandAcknowledgement(
            command,
            head: validHead,
            mutateResponse: { response in
                guard var receipt = response["receipt"] as? [String: Any] else { return }
                receipt["requestDigest"] = String(repeating: "0", count: 64)
                response["receipt"] = receipt
            }
        ),
        commandAcknowledgement(
            command,
            head: validHead,
            mutateEnvelope: { $0["workId"] = UUID().uuidString.lowercased() }
        ),
        commandAcknowledgement(
            command,
            head: validHead,
            mutateEnvelope: { envelope in
                guard var readBack = envelope["readBack"] as? [String: Any] else { return }
                readBack["stateMatched"] = false
                envelope["readBack"] = readBack
            }
        ),
        commandAcknowledgement(command, head: wrongHead),
        commandAcknowledgement(
            command,
            head: validHead,
            mutateResponse: { $0["unknown"] = true }
        ),
        commandAcknowledgement(
            command,
            status: 409,
            result: .parked,
            head: validHead
        ),
        commandAcknowledgement(
            command,
            status: 503,
            result: .retryable,
            head: validHead
        )
    ]
}

@Test
func remoteHeadRejectsNonJSONSafeGeneration() throws {
    let snapshot = try SnapshotID(rawValue: String(repeating: "a", count: 64))
    #expect(throws: SyncV2StoreError.invalidRemoteHead) {
        _ = try V2RemoteHead(
            snapshotID: snapshot,
            generation: V2RemoteHead.maximumGeneration + 1
        )
    }
}
