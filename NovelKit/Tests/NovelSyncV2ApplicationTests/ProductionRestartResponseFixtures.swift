import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

// swiftlint:disable:next function_body_length
func productionResponse(
    command: SealedCommand,
    result: V2CommandTerminalResult,
    head: V2RemoteHead?,
    cloneHead: V2RemoteHead?,
    status _: Int
) throws -> Data {
    let payload = try productionPayload(command)
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    let workID = try productionString(payload, key: workKey)
    let receipt: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "readBack": productionReadBack(),
        "requestDigest": command.requestDigest.rawValue,
        "workId": workID
    ]
    var response: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "receipt": receipt,
        "result": result.rawValue
    ]
    switch command.commandKind {
    case "prepareObject":
        if result == .applied {
            response["expiresAt"] = "2030-01-01T00:00:00Z"
            response["objectId"] = payload["objectId"]
            response["uploadCapability"] = String(repeating: "c", count: 32)
            response["uploadId"] = UUID().uuidString.lowercased()
        }
    case "registerSnapshot":
        response["head"] = NSNull()
        response["snapshotId"] = payload["snapshotId"]
    case "finalizeObject":
        response["byteCount"] = payload["byteCount"]
        response["head"] = NSNull()
        response["objectId"] = payload["objectId"]
    case "createWork":
        response["documentId"] = payload["documentId"]
        response["head"] = NSNull()
        response["workId"] = payload["workId"]
    case "resolveServer":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["head"] = head.map(productionHead) ?? NSNull()
        response["remoteGeneration"] = head?.generation as Any
        response["remoteSnapshotId"] = payload["remoteSnapshotId"]
    case "resolveDevice":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["generation"] = head?.generation as Any
        response["head"] = head.map(productionHead) ?? NSNull()
        response["snapshotId"] = payload["decisionSnapshotId"]
    case "cloneWork":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["head"] = cloneHead.map(productionHead) ?? NSNull()
        response["newRootSnapshotId"] = payload["newRootSnapshotId"]
        response["newWorkId"] = payload["newWorkId"]
    case "publish" where result == .conflictPending:
        response["conflictId"] = UUID().uuidString.lowercased()
        response["conflictRevision"] = 1
        response["head"] = head.map(productionHead) ?? NSNull()
        response["sourceGeneration"] = command.sourceGeneration
    default:
        response["generation"] = head?.generation as Any
        response["head"] = head.map(productionHead) ?? NSNull()
        response["snapshotId"] = payload["candidateSnapshotId"] ?? payload["snapshotId"] ?? NSNull()
    }
    return try productionJSON(response)
}

func productionHead(_ head: V2RemoteHead) -> [String: Any] {
    ["generation": head.generation, "snapshotId": head.snapshotID.rawValue]
}

func productionJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

extension Data {
    func productionBase64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
