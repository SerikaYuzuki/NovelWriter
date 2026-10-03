import Foundation
import NovelSyncV2
import NovelSyncV2Application
import Testing

@MainActor
func waitForCompletedCheckpointWorker(_ application: SyncV2Application, workID: WorkID) async throws {
    for _ in 0 ..< 200 {
        if await application.uiState(workID: workID)?.remoteProgress == .noChanges {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CheckpointRemoteFixtureError.workerDidNotComplete
}

private enum CheckpointRemoteFixtureError: Error { case workerDidNotComplete }

/// Acknowledge the actual sealed create/upload/register/publish flow so a no-op assertion
/// starts with a received checkpoint, rather than sampling an offline lane between retries.
func acknowledgeCheckpointTestCommand(_ operation: SyncV2SealedRemoteCommand) throws -> SyncV2RemoteExecution {
    let command = operation.command
    guard let payload = try JSONSerialization.jsonObject(with: command.payloadBytes) as? [String: Any],
          let workID = payload["workId"] as? String else { throw SyncV2Failure.receiptMismatch }
    let readBack: [String: Any] = [
        "accountMatched": true, "commandDigestMatched": true, "headMatched": true,
        "resourceMatched": true, "stateMatched": true
    ]
    let receipt: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(), "commandKind": command.commandKind,
        "readBack": readBack, "requestDigest": command.requestDigest.rawValue, "workId": workID
    ]
    var response: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(), "commandKind": command.commandKind,
        "receipt": receipt, "result": "applied"
    ]
    var head: SyncV2RemoteHead?
    switch operation.kind {
    case .createWork:
        response["documentId"] = payload["documentId"]
        response["workId"] = workID
        response["head"] = NSNull()
    case .prepareObject:
        response["expiresAt"] = "2030-01-01T00:00:00.123456+00:00"
        response["objectId"] = payload["objectId"]
        response["uploadCapability"] = String(repeating: "c", count: 32)
        response["uploadId"] = UUID().uuidString.lowercased()
    case .finalizeObject:
        response["byteCount"] = payload["byteCount"]
        response["objectId"] = payload["objectId"]
        response["head"] = NSNull()
    case .registerSnapshot:
        response["snapshotId"] = payload["snapshotId"]
        response["head"] = NSNull()
    case .publish:
        guard let snapshotID = payload["candidateSnapshotId"] as? String else { throw SyncV2Failure.receiptMismatch }
        head = try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: snapshotID), generation: command.sourceGeneration)
        response["head"] = ["generation": command.sourceGeneration, "snapshotId": snapshotID]
        response["generation"] = command.sourceGeneration
        response["snapshotId"] = snapshotID
    default:
        throw SyncV2Failure.receiptMismatch
    }
    let status = [.createWork, .prepareObject].contains(operation.kind) ? 201 : 200
    let responseData = try checkpointFixtureJSON(response)
    let envelope = try checkpointFixtureJSON([
        "canonicalResponseBase64URL": responseData.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
        "commandId": command.commandId.uuidString.lowercased(), "commandKind": command.commandKind,
        "originalResponseStatus": status, "originalResult": "applied", "readBack": readBack,
        "requestDigest": command.requestDigest.rawValue, "result": "noChanges", "workId": workID
    ])
    return .command(receipt: SyncV2ReceiptReadback(
        commandID: command.commandId, requestDigest: command.requestDigest, responseStatus: status,
        canonicalResponse: envelope,
        predicates: SyncV2ReadBackPredicates(accountMatched: true, commandDigestMatched: true,
                                             resourceMatched: true, headMatched: true, stateMatched: true),
        result: .applied, remoteHead: head
    ), remoteInbox: nil)
}

private func checkpointFixtureJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}
