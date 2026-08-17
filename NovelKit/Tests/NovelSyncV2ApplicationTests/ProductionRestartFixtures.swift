import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

func sourceStoreCommands(
    root: URL,
    workID: WorkID
) async throws -> [V2SealedCommandRecord] {
    let store = try LocalSyncV2Store(root: root, policy: .openExisting)
    return try await store.allSealedCommands(scope: productionScope, workID: workID)
}

func sealedCommand(
    _ operation: SyncV2RemoteOperation
) -> SyncV2SealedRemoteCommand? {
    guard case let .command(command) = operation else { return nil }
    return command
}

let productionScope = V2LocalWorkScope.bound(
    V2AccountBinding(
        accountID: "test-account",
        accountFence: "test-fence",
        serverInstanceID: "test-server"
    )
)

let productionBinding = V2AccountBinding(
    accountID: "test-account",
    accountFence: "test-fence",
    serverInstanceID: "test-server"
)

struct ProductionConflictFixture {
    let workID: WorkID
    let baseSnapshotID: SnapshotID
    let localSnapshotID: SnapshotID
    let sourceGeneration: Int64
    let remote: EncodedSnapshot
    let remoteHead: V2RemoteHead
}

// swiftlint:disable:next function_body_length
func seedProductionConflict(
    configuration: TestRuntimeConfiguration
) async throws -> ProductionConflictFixture {
    let store = try LocalSyncV2Store(
        root: configuration.localRoot.url,
        policy: .createNew
    )
    let workID = WorkID(UUID())
    let documentID = UUID()
    let base = try encodedProductionSnapshot(
        workID: workID,
        documentID: documentID,
        title: "基準",
        body: "基準"
    )
    let baseInbox = try V2RemoteSnapshot(
        workID: workID,
        encoded: base,
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: V2RemoteHead(snapshotID: base.snapshotId, generation: 1)
    )
    try await store.stageRemote(baseInbox, scope: productionScope)
    try await store.verifyInbox(inboxID: baseInbox.inboxID, scope: productionScope)
    try await store.adoptInbox(inboxID: baseInbox.inboxID, scope: productionScope)

    let localDocument = applicationTestDocument(id: documentID, title: "端末版", body: "端末")
    let localResult = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: applicationTestCreatedAt,
            expectedGeneration: 1,
            reason: .autosave
        ),
        scope: productionScope
    )
    let publish = try productionPublishCommand(
        workID: workID,
        checkpoint: localResult,
        expectedHead: V2RemoteHead(snapshotID: base.snapshotId, generation: 1)
    )
    try await store.seal(publish, intentID: localResult.intentID, scope: productionScope)

    let remote = try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: applicationTestDocument(id: documentID, title: "サーバー版", body: "サーバー"),
            documentCreatedAt: applicationTestCreatedAt
        ),
        parents: [base.snapshotId]
    )
    let remoteHead = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 3)
    let conflictDelivery = V2RemoteSnapshot(
        inboxID: UUID(),
        workID: workID,
        encoded: remote,
        expectedCurrentSnapshotID: localResult.snapshotID,
        expectedLocalGeneration: 2,
        expectedRemoteHead: remoteHead
    )
    let blockedReceipt = try productionAcknowledgement(
        publish,
        result: .conflictPending,
        status: 409,
        head: remoteHead
    )
    try await store.acknowledge(blockedReceipt, scope: productionScope)
    _ = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: base.snapshotId,
        localSnapshotID: localResult.snapshotID,
        remote: conflictDelivery,
        sourceGeneration: 2,
        scope: productionScope
    )
    return ProductionConflictFixture(
        workID: workID,
        baseSnapshotID: base.snapshotId,
        localSnapshotID: localResult.snapshotID,
        sourceGeneration: 2,
        remote: remote,
        remoteHead: remoteHead
    )
}

func encodedProductionSnapshot(
    workID: WorkID,
    documentID: UUID = UUID(),
    title: String,
    body: String
) throws -> EncodedSnapshot {
    try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: applicationTestDocument(id: documentID, title: title, body: body),
            documentCreatedAt: applicationTestCreatedAt
        ),
        parents: []
    )
}

final class ProductionPublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func allow() {
        lock.lock(); defer { lock.unlock() }
        enabled = true
    }

    func isAllowed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }
}

func installProductionResponder(
    _ remote: FakeSyncV2RemoteClient,
    fixture: ProductionConflictFixture,
    publishGate: ProductionPublishGate? = nil
) async {
    await remote.setCommandHandler { command in
        if command.kind == .publish, let publishGate, !publishGate.isAllowed() {
            throw SyncV2Failure.offline
        }
        return try productionExecution(command, fixture: fixture)
    }
}

func productionPublishCommand(
    workID: WorkID,
    checkpoint: V2CheckpointResult,
    expectedHead: V2RemoteHead
) throws -> SealedCommand {
    let envelope: [String: Any] = [
        "binding": [
            "accountFence": productionBinding.accountFence,
            "accountId": productionBinding.accountID,
            "protocolEpoch": productionBinding.protocolEpoch,
            "serverInstanceId": productionBinding.serverInstanceID
        ],
        "commandId": UUID().uuidString.lowercased(),
        "commandKind": "publish",
        "payload": [
            "candidateSnapshotId": checkpoint.snapshotID.rawValue,
            "expectedRemoteHead": productionHead(expectedHead),
            "workId": workID.description
        ],
        "schemaVersion": 2,
        "sourceGeneration": checkpoint.generation,
        "sourceSnapshotId": checkpoint.snapshotID.rawValue
    ]
    return try SealedCommand.decodeCanonical(productionJSON(envelope))
}

func productionPayload(_ command: SealedCommand) throws -> [String: Any] {
    let object = try productionDictionary(command.canonicalBytes)
    guard let payload = object["payload"] as? [String: Any] else {
        throw SyncV2Failure.receiptMismatch
    }
    return payload
}

func productionExecution(
    _ command: SyncV2SealedRemoteCommand,
    fixture: ProductionConflictFixture
) throws -> SyncV2RemoteExecution {
    let kind = command.kind
    let payload = try productionPayload(command.command)
    let result: V2CommandTerminalResult = kind == .prepareObject ? .noChanges : .applied
    let status = kind == .createWork ? 201 : 200
    let head = try productionRemoteHead(kind: kind, payload: payload, fixture: fixture)
    let cloneHead = try productionCloneHead(kind: kind, payload: payload)
    let response = try productionResponse(
        command: command.command,
        result: result,
        head: head,
        cloneHead: cloneHead,
        status: status
    )
    let envelope = try productionEnvelope(
        command: command.command,
        response: response,
        result: result,
        status: status
    )
    let receipt = SyncV2ReceiptReadback(
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
        result: .applied,
        remoteHead: head.flatMap { try? SyncV2RemoteHead(snapshotID: $0.snapshotID, generation: $0.generation) },
        cloneRemoteHead: cloneHead.flatMap {
            try? SyncV2RemoteHead(snapshotID: $0.snapshotID, generation: $0.generation)
        }
    )
    return .command(receipt: receipt, remoteInbox: nil)
}

func productionRemoteHead(
    kind: SyncV2RemoteOperationKind,
    payload: [String: Any],
    fixture: ProductionConflictFixture
) throws -> V2RemoteHead? {
    switch kind {
    case .resolveServer, .cloneWork:
        return fixture.remoteHead
    case .resolveDevice:
        let decisionSnapshotID = try productionString(payload, key: "decisionSnapshotId")
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: decisionSnapshotID),
            generation: 4
        )
    case .publish:
        let candidate = try productionString(payload, key: "candidateSnapshotId")
        let expectedGeneration = (payload["expectedRemoteHead"] as? [String: Any])?["generation"] as? NSNumber
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: candidate),
            generation: (expectedGeneration?.int64Value ?? fixture.remoteHead.generation) + 1
        )
    default:
        return nil
    }
}

func productionCloneHead(
    kind: SyncV2RemoteOperationKind,
    payload: [String: Any]
) throws -> V2RemoteHead? {
    guard kind == .cloneWork else { return nil }
    let newRootSnapshotID = try productionString(payload, key: "newRootSnapshotId")
    return try V2RemoteHead(
        snapshotID: SnapshotID(rawValue: newRootSnapshotID),
        generation: 1
    )
}

func productionAcknowledgement(
    _ command: SealedCommand,
    result: V2CommandTerminalResult,
    status: Int,
    head: V2RemoteHead
) throws -> V2CommandAcknowledgement {
    let response = try productionResponse(
        command: command,
        result: result,
        head: head,
        cloneHead: nil,
        status: status
    )
    let readBack = productionReadBack()
    let payload = try productionPayload(command)
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    let workID = try productionString(payload, key: workKey)
    let envelope: [String: Any] = [
        "canonicalResponseBase64URL": response.productionBase64URL(),
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "originalResponseStatus": status,
        "originalResult": result.rawValue,
        "readBack": readBack,
        "requestDigest": command.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ]
    return try V2CommandAcknowledgement(
        commandID: command.commandId,
        canonicalReceiptEnvelope: productionJSON(envelope)
    )
}

func productionEnvelope(
    command: SealedCommand,
    response: Data,
    result: V2CommandTerminalResult,
    status: Int
) throws -> Data {
    let payload = try productionPayload(command)
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    let workID = try productionString(payload, key: workKey)
    let envelope: [String: Any] = [
        "canonicalResponseBase64URL": response.productionBase64URL(),
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "originalResponseStatus": status,
        "originalResult": result.rawValue,
        "readBack": productionReadBack(),
        "requestDigest": command.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ]
    return try productionJSON(envelope)
}

func productionReadBack() -> [String: Any] {
    [
        "accountMatched": true,
        "commandDigestMatched": true,
        "headMatched": true,
        "resourceMatched": true,
        "stateMatched": true
    ]
}

func productionDictionary(_ data: Data) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SyncV2Failure.receiptMismatch
    }
    return dictionary
}

func productionString(_ dictionary: [String: Any], key: String) throws -> String {
    guard let value = dictionary[key] as? String else {
        throw SyncV2Failure.receiptMismatch
    }
    return value
}
