import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Snapshot Sync v2 planner scope caches")
struct PlannerScopeCacheTests {
    @Test("a newer generation never finalizes with an older transfer session")
    // swiftlint:disable:next function_body_length
    func newerGenerationDoesNotReuseOlderTransferSession() async throws {
        let remote = FakeSyncV2RemoteClient()
        await remote.setCommandHandler { command in
            let status = command.kind == .prepareObject || command.kind == .createWork ? 201 : 200
            let payload = try productionPayload(command.command)
            let head: V2RemoteHead? = if command.kind == .publish,
                                         let raw = payload["candidateSnapshotId"] as? String {
                try V2RemoteHead(
                    snapshotID: SnapshotID(rawValue: raw),
                    generation: command.command.sourceGeneration
                )
            } else {
                nil
            }
            let response = try productionResponse(
                command: command.command,
                result: .applied,
                head: head,
                cloneHead: nil,
                status: status
            )
            let envelope = try productionEnvelope(
                command: command.command,
                response: response,
                result: .applied,
                status: status
            )
            return .command(
                receipt: SyncV2ReceiptReadback(
                    commandID: command.command.commandId,
                    requestDigest: command.command.requestDigest,
                    responseStatus: status,
                    canonicalResponse: envelope,
                    predicates: SyncV2ReadBackPredicates(
                        accountMatched: true,
                        commandDigestMatched: true,
                        resourceMatched: true,
                        headMatched: true,
                        stateMatched: true
                    ),
                    result: .applied
                ),
                remoteInbox: nil
            )
        }
        let configuration = try TestRuntimeConfiguration(remote: remote)
        let seedStore = try LocalSyncV2Store(
            root: configuration.localRoot.url,
            policy: .createNew
        )
        let workID = WorkID(UUID())
        let firstDocument = applicationTestDocument(title: "初版", body: "不変本文")
        let seed = try encodedProductionSnapshot(
            workID: workID,
            documentID: firstDocument.id,
            title: firstDocument.title,
            body: "不変本文"
        )
        let inbox = try V2RemoteSnapshot(
            workID: workID,
            encoded: seed,
            expectedCurrentSnapshotID: nil,
            expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(snapshotID: seed.snapshotId, generation: 1)
        )
        try await seedStore.stageRemote(inbox, scope: productionScope)
        try await seedStore.verifyInbox(inboxID: inbox.inboxID, scope: productionScope)
        try await seedStore.adoptInbox(inboxID: inbox.inboxID, scope: productionScope)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await app.checkpoint(
            workID: workID,
            document: firstDocument,
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await app.resumePending()
        try await eventually {
            try await LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
                .pendingIntents(scope: productionScope, workID: workID).isEmpty
        }

        let firstOperations = await remote.recordedOperations()
        let oldUploadIDs = Set(firstOperations.compactMap { operation -> UUID? in
            guard case let .upload(upload) = operation else { return nil }
            return upload.uploadID
        })
        #expect(!oldUploadIDs.isEmpty)

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(
                id: firstDocument.id,
                title: "二版",
                body: "不変本文"
            ),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await app.resumePending()
        try await eventually {
            try await LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
                .pendingIntents(scope: productionScope, workID: workID).isEmpty
        }

        let secondOperations = await remote.recordedOperations()
        let reusedOldUploadIDs = secondOperations.compactMap { operation -> UUID? in
            guard case let .command(command) = operation, command.kind == .finalizeObject else { return nil }
            return (try? productionPayload(command.command)["uploadId"] as? String)
                .flatMap(UUID.init(uuidString:))
        }.filter(oldUploadIDs.contains)
        #expect(reusedOldUploadIDs.isEmpty)
    }
}
