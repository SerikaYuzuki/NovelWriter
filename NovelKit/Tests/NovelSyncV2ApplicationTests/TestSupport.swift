import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

let applicationTestCreatedAt = Date(timeIntervalSince1970: 1_720_000_000)

func applicationTestDocument(
    id: UUID = UUID(),
    title: String = "原稿",
    body: String = "本文"
) -> NovelDocument {
    NovelDocument(
        id: id,
        title: title,
        chapters: [Chapter(title: "第一章", content: body, memo: "メモ")]
    )
}

func applicationTestComposition(
    state: InMemorySyncV2RuntimeState,
    remote: any SyncV2RemoteClient,
    gate: InMemorySyncV2DocumentGate = InMemorySyncV2DocumentGate(),
    identity: SyncV2RuntimeComposition.Identity = .test
) -> SyncV2RuntimeComposition {
    SyncV2RuntimeComposition(
        identity: identity,
        kernel: state,
        planner: state,
        remote: remote,
        gate: gate,
        library: state
    )
}

func applicationTestApp(
    state: InMemorySyncV2RuntimeState,
    remote: any SyncV2RemoteClient,
    gate: InMemorySyncV2DocumentGate = InMemorySyncV2DocumentGate()
) throws -> SyncV2Application {
    let configuration = try TestRuntimeConfiguration()
    return try SyncV2Application(
        mode: .test(configuration),
        composition: applicationTestComposition(
            state: state,
            remote: remote,
            gate: gate
        )
    )
}

func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition did not become true before timeout")
}

func commandKind(
    _ operation: SyncV2RemoteOperation
) -> SyncV2RemoteOperationKind? {
    guard case let .command(command) = operation else { return nil }
    return command.kind
}

actor ApplicationTestRemote: SyncV2RemoteClient {
    enum Reply: Sendable {
        case applied(inbox: SyncV2RemoteInbox? = nil)
        case noChanges(inbox: SyncV2RemoteInbox? = nil)
        case conflict(SyncV2ConflictProjection)
        case failure(SyncV2Failure)
        case suspendThenFailure(SyncV2Failure)
    }

    private var replies: [Reply]
    private var operations: [SyncV2RemoteOperation] = []
    private var suspended: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func execute(
        _ operation: SyncV2RemoteOperation
    ) async throws -> SyncV2RemoteExecution {
        operations.append(operation)
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        switch reply {
        case let .failure(failure):
            throw failure
        case let .suspendThenFailure(failure):
            await withCheckedContinuation { suspended.append($0) }
            throw failure
        case let .applied(inbox):
            return try execution(operation, result: .applied, inbox: inbox)
        case let .noChanges(inbox):
            return try execution(operation, result: .noChanges, inbox: inbox)
        case let .conflict(conflict):
            return try execution(
                operation,
                result: .conflictPending,
                inbox: nil,
                conflict: conflict
            )
        }
    }

    func recordedOperations() -> [SyncV2RemoteOperation] {
        operations
    }

    func resumeSuspended() {
        let continuations = suspended
        suspended.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func execution(
        _ operation: SyncV2RemoteOperation,
        result: SyncV2RemoteResult,
        inbox: SyncV2RemoteInbox?,
        conflict: SyncV2ConflictProjection? = nil
    ) throws -> SyncV2RemoteExecution {
        switch operation {
        case let .command(sealed):
            .command(
                receipt: SyncV2ReceiptReadback(
                    commandID: sealed.command.commandId,
                    requestDigest: sealed.command.requestDigest,
                    responseStatus: 200,
                    canonicalResponse: Data("{}".utf8),
                    predicates: SyncV2ReadBackPredicates(
                        accountMatched: true,
                        commandDigestMatched: true,
                        resourceMatched: true,
                        headMatched: true,
                        stateMatched: true
                    ),
                    result: result,
                    verifiedInboxID: inbox?.inboxID,
                    conflict: conflict
                ),
                remoteInbox: inbox
            )
        case let .upload(upload):
            .upload(SyncV2UploadCompletion(
                transferID: upload.transferID,
                uploadID: upload.uploadID,
                objectID: upload.objectID,
                acknowledgedByteCount: upload.exactBytes.count
            ))
        }
    }
}

func applicationTestInbox(
    workID: WorkID,
    document: NovelDocument,
    currentSnapshotID: SnapshotID?,
    localGeneration: Int64
) throws -> SyncV2RemoteInbox {
    let encoded = try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: document,
            documentCreatedAt: applicationTestCreatedAt
        ),
        parents: []
    )
    return try SyncV2RemoteInbox(
        inboxID: UUID(),
        workID: workID,
        headSnapshotID: encoded.snapshotId,
        snapshots: [encoded],
        expectedCurrentSnapshotID: currentSnapshotID,
        expectedLocalGeneration: localGeneration,
        expectedRemoteHead: SyncV2RemoteHead(
            snapshotID: encoded.snapshotId,
            generation: 1
        )
    )
}
