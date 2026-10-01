import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

struct ReceiptEquivalenceTests {
    @Test(arguments: 0 ... 10)
    func existingVectors(index: Int) async throws {
        let root = temporaryStoreRoot("receipt-equivalence")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let workID = WorkID(UUID())
        let checkpoint = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: makeDocument(title: "receipt"), documentCreatedAt: testDate,
            expectedGeneration: 0, reason: .explicit
        ), scope: scopeA)
        let command = try publishCommand(workID: workID, checkpoint: checkpoint)
        try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
        let record = try #require(await store.allSealedCommands(scope: scopeA, workID: workID).first)
        let head = try V2RemoteHead(snapshotID: checkpoint.snapshotID, generation: 1)
        let wrongHead = try V2RemoteHead(snapshotID: SnapshotID(rawValue: String(repeating: "b", count: 64)), generation: 1)
        let vectors = try [commandAcknowledgement(command, head: head)] + invalidAcknowledgements(
            command: command, validHead: head, wrongHead: wrongHead
        )
        let allVectors = try vectors + [commandAcknowledgement(command, head: head, mutateEnvelope: { envelope in
            envelope["readBack"] = ["accountMatched": 1, "commandDigestMatched": 1, "resourceMatched": 1,
                                    "headMatched": 1, "stateMatched": 1]
        })]
        // This acceptance table was checked against the old Store decoder before its removal.
        let new = try? await store.decodeAcknowledgement(allVectors[index], record: record)
        #expect((new != nil) == (index == 0))
        await store.close()
    }
}
