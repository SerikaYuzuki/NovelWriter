import CSQLite
import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store

let testDate = Date(timeIntervalSince1970: 1_700_000_000)
let bindingA = V2AccountBinding(
    accountID: "account-a",
    accountFence: "fence-a",
    serverInstanceID: "server-a"
)
let scopeA = V2LocalWorkScope.bound(bindingA)

func temporaryStoreRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fuminiwa-v2-\(label)-\(UUID().uuidString)")
}

func sqliteRejectedByConstraint(databaseURL: URL, sql: String) throws -> Bool {
    let result = try sqliteResult(databaseURL: databaseURL, sql: sql)
    return result == SQLITE_CONSTRAINT || result & 0xFF == SQLITE_CONSTRAINT
}

func sqliteExecutionSucceeded(databaseURL: URL, sql: String) throws -> Bool {
    try sqliteResult(databaseURL: databaseURL, sql: sql) == SQLITE_OK
}

private func sqliteResult(databaseURL: URL, sql: String) throws -> Int32 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK,
        let database else {
        throw SyncV2StoreError.sqlite("test open")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK else {
        throw SyncV2StoreError.sqlite("test foreign keys")
    }
    return sqlite3_exec(database, sql, nil, nil, nil)
}

func makeDocument(title: String, id: UUID = UUID()) -> NovelDocument {
    NovelDocument(
        id: id,
        title: title,
        chapters: [Chapter(title: "chapter", content: "body")]
    )
}

func encodeSnapshot(
    workID: WorkID,
    document: NovelDocument,
    parents: [SnapshotID] = []
) throws -> EncodedSnapshot {
    try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: document,
            documentCreatedAt: testDate
        ),
        parents: parents
    )
}

func joinedJSON(_ fragments: String...) -> String {
    fragments.joined()
}

func canonicalCommand(
    kind: String,
    commandID: UUID = UUID(),
    sourceGeneration: Int64,
    sourceSnapshotID: SnapshotID,
    binding: V2AccountBinding = bindingA,
    payload: String
) throws -> SealedCommand {
    let json = joinedJSON(
        "{\"binding\":{\"accountFence\":\"", binding.accountFence,
        "\",\"accountId\":\"", binding.accountID,
        "\",\"protocolEpoch\":", String(binding.protocolEpoch),
        ",\"serverInstanceId\":\"", binding.serverInstanceID,
        "\"},\"commandId\":\"", commandID.uuidString.lowercased(),
        "\",\"commandKind\":\"", kind,
        "\",\"payload\":", payload,
        ",\"schemaVersion\":2,\"sourceGeneration\":", String(sourceGeneration),
        ",\"sourceSnapshotId\":\"", sourceSnapshotID.rawValue, "\"}"
    )
    return try SealedCommand.decodeCanonical(Data(json.utf8))
}

func headJSON(_ head: V2RemoteHead?) -> String {
    guard let head else { return "null" }
    return "{\"generation\":\(head.generation),\"snapshotId\":\"\(head.snapshotID.rawValue)\"}"
}

func publishCommand(
    workID: WorkID,
    checkpoint: V2CheckpointResult,
    expectedHead: V2RemoteHead? = nil,
    commandID: UUID = UUID(),
    binding: V2AccountBinding = bindingA
) throws -> SealedCommand {
    try canonicalCommand(
        kind: "publish",
        commandID: commandID,
        sourceGeneration: checkpoint.generation,
        sourceSnapshotID: checkpoint.snapshotID,
        binding: binding,
        payload: joinedJSON(
            "{\"candidateSnapshotId\":\"", checkpoint.snapshotID.rawValue,
            "\",\"expectedRemoteHead\":", headJSON(expectedHead),
            ",\"workId\":\"", workID.description, "\"}"
        )
    )
}

func createWorkCommand(
    workID: WorkID,
    documentID: UUID,
    checkpoint: V2CheckpointResult,
    commandID: UUID = UUID()
) throws -> SealedCommand {
    try canonicalCommand(
        kind: "createWork",
        commandID: commandID,
        sourceGeneration: checkpoint.generation,
        sourceSnapshotID: checkpoint.snapshotID,
        payload: "{\"documentId\":\"\(documentID.uuidString.lowercased())\",\"workId\":\"\(workID.description)\"}"
    )
}

func resolveDeviceCommand(
    workID: WorkID,
    conflict: V2ConflictCandidate,
    decision: V2CheckpointResult,
    expectedHead: V2RemoteHead,
    commandID: UUID = UUID()
) throws -> SealedCommand {
    try canonicalCommand(
        kind: "resolveDevice",
        commandID: commandID,
        sourceGeneration: conflict.sourceGeneration,
        sourceSnapshotID: conflict.localSnapshotID,
        payload: joinedJSON(
            "{\"conflictId\":\"", conflict.conflictID.uuidString.lowercased(),
            "\",\"conflictRevision\":", String(conflict.revision),
            ",\"decisionSnapshotId\":\"", decision.snapshotID.rawValue,
            "\",\"expectedRemoteHead\":", headJSON(expectedHead),
            ",\"localCandidateSnapshotId\":\"", conflict.localSnapshotID.rawValue,
            "\",\"workId\":\"", workID.description, "\"}"
        )
    )
}

func resolveServerCommand(
    workID: WorkID,
    conflict: V2ConflictCandidate,
    commandID: UUID = UUID()
) throws -> SealedCommand {
    try canonicalCommand(
        kind: "resolveServer",
        commandID: commandID,
        sourceGeneration: conflict.sourceGeneration,
        sourceSnapshotID: conflict.localSnapshotID,
        payload: joinedJSON(
            "{\"conflictId\":\"", conflict.conflictID.uuidString.lowercased(),
            "\",\"conflictRevision\":", String(conflict.revision),
            ",\"expectedCurrentSnapshotId\":\"", conflict.localSnapshotID.rawValue,
            "\",\"expectedLocalGeneration\":", String(conflict.sourceGeneration),
            ",\"preAdoptionSnapshotId\":\"", conflict.localSnapshotID.rawValue,
            "\",\"remoteSnapshotId\":\"", conflict.remoteSnapshotID.rawValue,
            "\",\"workId\":\"", workID.description, "\"}"
        )
    )
}

func cloneWorkCommand(
    conflict: V2ConflictCandidate,
    reservation: V2KeepBothReservation,
    expectedHead: V2RemoteHead,
    commandID: UUID = UUID()
) throws -> SealedCommand {
    try canonicalCommand(
        kind: "cloneWork",
        commandID: commandID,
        sourceGeneration: conflict.sourceGeneration,
        sourceSnapshotID: conflict.localSnapshotID,
        payload: joinedJSON(
            "{\"conflictId\":\"", conflict.conflictID.uuidString.lowercased(),
            "\",\"conflictRevision\":", String(conflict.revision),
            ",\"expectedOriginalHead\":", headJSON(expectedHead),
            ",\"localCandidateSnapshotId\":\"", conflict.localSnapshotID.rawValue,
            "\",\"newDocumentId\":\"", reservation.newDocumentID.description,
            "\",\"newRootSnapshotId\":\"", reservation.newRootSnapshotID.rawValue,
            "\",\"newWorkId\":\"", reservation.newWorkID.description,
            "\",\"sourceWorkId\":\"", conflict.workID.description, "\"}"
        )
    )
}

func restoreCommand(
    workID: WorkID,
    source: V2CheckpointResult,
    selected: SnapshotID,
    restored: V2RestorePreparationResult,
    expectedHead: V2RemoteHead? = nil,
    commandID: UUID = UUID()
) throws -> SealedCommand {
    try canonicalCommand(
        kind: "restore",
        commandID: commandID,
        sourceGeneration: source.generation,
        sourceSnapshotID: source.snapshotID,
        payload: joinedJSON(
            "{\"expectedCurrentSnapshotId\":\"", source.snapshotID.rawValue,
            "\",\"expectedLocalGeneration\":", String(source.generation),
            ",\"expectedRemoteHead\":", headJSON(expectedHead ?? restored.expectedRemoteHead),
            ",\"newSnapshotId\":\"", restored.checkpoint.snapshotID.rawValue,
            "\",\"selectedSnapshotId\":\"", selected.rawValue,
            "\",\"workId\":\"", workID.description, "\"}"
        )
    )
}

let verifiedPredicates = V2ReadBackPredicates(
    accountMatched: true,
    commandDigestMatched: true,
    resourceMatched: true,
    headMatched: true,
    stateMatched: true
)

func commandAcknowledgement(
    _ command: SealedCommand,
    status: Int = 200,
    result: V2CommandTerminalResult = .applied,
    head: V2RemoteHead? = nil,
    predicates: V2ReadBackPredicates = verifiedPredicates,
    mutateResponse: ((inout [String: Any]) -> Void)? = nil,
    mutateEnvelope: ((inout [String: Any]) -> Void)? = nil
) throws -> V2CommandAcknowledgement {
    let commandObject = try jsonObject(command.canonicalBytes)
    guard let payload = commandObject["payload"] as? [String: Any] else {
        throw SyncV2StoreError.invalidCommand
    }
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    guard let workID = payload[workKey] as? String else {
        throw SyncV2StoreError.invalidCommand
    }
    let readBack = readBackObject(predicates)
    let receipt: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "readBack": readBack,
        "requestDigest": command.requestDigest.rawValue,
        "workId": workID
    ]
    var response: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "receipt": receipt,
        "result": result.rawValue
    ]
    try addResponseFields(
        &response,
        command: command,
        payload: payload,
        result: result,
        head: head
    )
    mutateResponse?(&response)
    let responseBytes = try canonicalJSON(response)
    var envelope: [String: Any] = [
        "canonicalResponseBase64URL": responseBytes.testBase64URL,
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "originalResponseStatus": status,
        "originalResult": result.rawValue,
        "readBack": readBack,
        "requestDigest": command.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ]
    mutateEnvelope?(&envelope)
    return try V2CommandAcknowledgement(
        commandID: command.commandId,
        canonicalReceiptEnvelope: canonicalJSON(envelope)
    )
}

private func addResponseFields(
    _ response: inout [String: Any],
    command: SealedCommand,
    payload: [String: Any],
    result: V2CommandTerminalResult,
    head: V2RemoteHead?
) throws {
    let headValue: Any = head.map(headObject) ?? NSNull()
    switch command.commandKind {
    case "createWork":
        response["documentId"] = payload["documentId"]
        response["head"] = NSNull()
        response["workId"] = payload["workId"]
    case "prepareObject":
        if result == .applied {
            response["expiresAt"] = "2030-01-01T00:00:00Z"
            response["objectId"] = payload["objectId"]
            response["uploadCapability"] = String(repeating: "c", count: 32)
            response["uploadId"] = UUID().uuidString.lowercased()
        }
    case "finalizeObject":
        response["byteCount"] = payload["byteCount"]
        response["head"] = headValue
        response["objectId"] = payload["objectId"]
    case "registerSnapshot":
        response["head"] = headValue
        response["snapshotId"] = payload["snapshotId"]
    case "publish":
        if result == .conflictPending {
            response["conflictId"] = UUID().uuidString.lowercased()
            response["conflictRevision"] = 1
            response["head"] = headValue
            response["sourceGeneration"] = command.sourceGeneration
        } else {
            response["generation"] = head?.generation
            response["head"] = headValue
            response["snapshotId"] = payload["candidateSnapshotId"]
        }
    case "resolveDevice":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["generation"] = head?.generation
        response["head"] = headValue
        response["snapshotId"] = payload["decisionSnapshotId"]
    case "resolveServer":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["head"] = headValue
        response["remoteGeneration"] = head?.generation
        response["remoteSnapshotId"] = payload["remoteSnapshotId"]
    case "cloneWork":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["head"] = headValue
        response["newRootSnapshotId"] = payload["newRootSnapshotId"]
        response["newWorkId"] = payload["newWorkId"]
    case "restore":
        response["generation"] = head?.generation
        response["head"] = headValue
        response["protectedRestoreBeforeSnapshotId"] = command.sourceSnapshotId.rawValue
        response["snapshotId"] = payload["newSnapshotId"]
    default:
        throw SyncV2StoreError.invalidCommand
    }
}

private func readBackObject(_ value: V2ReadBackPredicates) -> [String: Any] {
    [
        "accountMatched": value.accountMatched,
        "commandDigestMatched": value.commandDigestMatched,
        "headMatched": value.headMatched,
        "resourceMatched": value.resourceMatched,
        "stateMatched": value.stateMatched
    ]
}

private func headObject(_ head: V2RemoteHead) -> [String: Any] {
    ["generation": head.generation, "snapshotId": head.snapshotID.rawValue]
}

private func canonicalJSON(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func jsonObject(_ value: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: value) as? [String: Any] else {
        throw SyncV2StoreError.invalidCommand
    }
    return object
}

private extension Data {
    var testBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ConflictFixture {
    let baseCheckpoint: V2CheckpointResult
    let localDocument: NovelDocument
    let localCheckpoint: V2CheckpointResult
    let remote: V2RemoteSnapshot
    let remoteHead: V2RemoteHead
    let conflict: V2ConflictCandidate
}

func createConflict(
    store: LocalSyncV2Store,
    workID: WorkID,
    localTitle: String = "local",
    remoteTitle: String = "remote"
) async throws -> ConflictFixture {
    var local = makeDocument(title: "base")
    let baseCheckpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: local,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    local.title = localTitle
    let localCheckpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: local,
            documentCreatedAt: testDate,
            expectedGeneration: baseCheckpoint.generation
        ),
        scope: scopeA
    )
    let remoteDocument = NovelDocument(
        id: local.id,
        title: remoteTitle,
        chapters: local.chapters
    )
    let encoded = try encodeSnapshot(
        workID: workID,
        document: remoteDocument,
        parents: [baseCheckpoint.snapshotID]
    )
    let remoteHead = try V2RemoteHead(snapshotID: encoded.snapshotId, generation: 2)
    let remote = V2RemoteSnapshot(
        workID: workID,
        encoded: encoded,
        expectedCurrentSnapshotID: localCheckpoint.snapshotID,
        expectedLocalGeneration: localCheckpoint.generation,
        expectedRemoteHead: remoteHead
    )
    let conflict = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: baseCheckpoint.snapshotID,
        localSnapshotID: localCheckpoint.snapshotID,
        remote: remote,
        sourceGeneration: localCheckpoint.generation,
        scope: scopeA
    )
    return ConflictFixture(
        baseCheckpoint: baseCheckpoint,
        localDocument: local,
        localCheckpoint: localCheckpoint,
        remote: remote,
        remoteHead: remoteHead,
        conflict: conflict
    )
}
