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
            ",\"expectedRemoteHead\":", headJSON(expectedHead),
            ",\"newSnapshotId\":\"", restored.checkpoint.snapshotID.rawValue,
            "\",\"selectedSnapshotId\":\"", selected.rawValue,
            "\",\"workId\":\"", workID.description, "\"}"
        )
    )
}

let verifiedPredicates = V2ReadBackPredicates(
    commandMatched: true,
    digestMatched: true,
    resourceMatched: true,
    headMatched: true
)

struct ConflictFixture {
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
    let local = makeDocument(title: localTitle)
    let localCheckpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: local,
            documentCreatedAt: testDate,
            expectedGeneration: 0
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
        parents: [localCheckpoint.snapshotID]
    )
    let remoteHead = try V2RemoteHead(snapshotID: encoded.snapshotId, generation: 2)
    let remote = V2RemoteSnapshot(
        workID: workID,
        encoded: encoded,
        expectedCurrentSnapshotID: localCheckpoint.snapshotID,
        expectedLocalGeneration: 1,
        expectedRemoteHead: remoteHead
    )
    let conflict = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: localCheckpoint.snapshotID,
        localSnapshotID: localCheckpoint.snapshotID,
        remote: remote,
        sourceGeneration: 1,
        scope: scopeA
    )
    return ConflictFixture(
        localDocument: local,
        localCheckpoint: localCheckpoint,
        remote: remote,
        remoteHead: remoteHead,
        conflict: conflict
    )
}
