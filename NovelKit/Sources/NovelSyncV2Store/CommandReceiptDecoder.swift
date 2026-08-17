import CoreFoundation
import Foundation
import NovelCore
import NovelSyncV2

struct DecodedCommandAcknowledgement: Sendable {
    let commandID: UUID
    let responseStatus: Int
    let canonicalResponse: Data
    let result: V2CommandTerminalResult
    let predicates: V2ReadBackPredicates
    let remoteHead: V2RemoteHead?
    let cloneRemoteHead: V2RemoteHead?
}

extension LocalSyncV2Store {
    func decodeAcknowledgement(
        _ acknowledgement: V2CommandAcknowledgement,
        record: V2SealedCommandRecord
    ) throws -> DecodedCommandAcknowledgement {
        try CanonicalJSON.validate(acknowledgement.canonicalReceiptEnvelope)
        let envelope = try strictJSONObject(acknowledgement.canonicalReceiptEnvelope)
        try requireKeys(
            envelope,
            exactly: [
                "canonicalResponseBase64URL", "commandId", "commandKind",
                "originalResponseStatus", "originalResult", "readBack",
                "requestDigest", "result", "workId"
            ]
        )
        guard try uuid(envelope, "commandId") == record.commandID,
              try string(envelope, "commandKind") == record.commandKind,
              try string(envelope, "requestDigest") == record.requestDigest.rawValue,
              try uuid(envelope, "workId").uuidString.lowercased() == record.workID.description,
              try string(envelope, "result") == "noChanges" else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        let envelopePredicates = try readBack(envelope["readBack"])
        guard envelopePredicates.allVerified,
              let encodedResponse = envelope["canonicalResponseBase64URL"] as? String,
              let responseBytes = Data(strictBase64URL: encodedResponse) else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        try CanonicalJSON.validate(responseBytes)
        let response = try strictJSONObject(responseBytes)
        guard let result = try V2CommandTerminalResult(
            rawValue: string(response, "result")
        ),
            try result.rawValue == string(envelope, "originalResult"),
            result != .retryable,
            result != .parked else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        let status = try integer(envelope, "originalResponseStatus")
        try validateStatus(Int(status), commandKind: record.commandKind, result: result)

        let receipt = try dictionary(response["receipt"])
        try requireKeys(
            receipt,
            exactly: ["commandId", "commandKind", "readBack", "requestDigest", "workId"]
        )
        let bodyPredicates = try readBack(receipt["readBack"])
        guard try uuid(receipt, "commandId") == record.commandID,
              try string(receipt, "commandKind") == record.commandKind,
              try string(receipt, "requestDigest") == record.requestDigest.rawValue,
              try uuid(receipt, "workId").uuidString.lowercased() == record.workID.description,
              bodyPredicates == envelopePredicates else {
            throw SyncV2StoreError.invalidAcknowledgement
        }

        let command = try SealedCommand.decodeCanonical(record.canonicalRequest)
        let payload = try command.payloadDictionary()
        let responseHead = try validateCommandResponse(
            response,
            record: record,
            payload: payload,
            result: result
        )
        let heads = try acknowledgementHeads(
            commandKind: record.commandKind,
            payload: payload,
            responseHead: responseHead
        )
        return DecodedCommandAcknowledgement(
            commandID: record.commandID,
            responseStatus: Int(status),
            canonicalResponse: responseBytes,
            result: result,
            predicates: bodyPredicates,
            remoteHead: heads.remote,
            cloneRemoteHead: heads.clone
        )
    }

    private func acknowledgementHeads(
        commandKind: String,
        payload: [String: Any],
        responseHead: V2RemoteHead?
    ) throws -> (remote: V2RemoteHead?, clone: V2RemoteHead?) {
        if commandKind == "cloneWork" {
            guard let clone = responseHead,
                  let original = try payload.remoteHead("expectedOriginalHead") else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            return (original, clone)
        }
        return (responseHead, nil)
    }

    private func validateStatus(
        _ status: Int,
        commandKind: String,
        result: V2CommandTerminalResult
    ) throws {
        let expectedStatus: Int? = switch (commandKind, result) {
        case ("createWork", .applied), ("prepareObject", .applied): 201
        case ("prepareObject", .noChanges),
             ("finalizeObject", .applied),
             ("registerSnapshot", .applied),
             ("registerSnapshot", .noChanges),
             ("publish", .applied),
             ("resolveDevice", .applied),
             ("resolveServer", .applied),
             ("cloneWork", .applied),
             ("restore", .applied): 200
        case ("publish", .conflictPending): 409
        default: nil
        }
        guard status == expectedStatus else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }

    private func validateCommandResponse(
        _ response: [String: Any],
        record: V2SealedCommandRecord,
        payload: [String: Any],
        result: V2CommandTerminalResult
    ) throws -> V2RemoteHead? {
        let base: Set = ["commandId", "commandKind", "receipt", "result"]
        let extras: Set<String>
        switch (record.commandKind, result) {
        case ("createWork", _):
            extras = ["documentId", "head", "workId"]
        case ("prepareObject", .noChanges):
            extras = []
        case ("prepareObject", .applied):
            extras = ["expiresAt", "objectId", "uploadCapability", "uploadId"]
        case ("finalizeObject", _):
            extras = ["byteCount", "head", "objectId"]
        case ("registerSnapshot", _):
            extras = ["head", "snapshotId"]
        case ("publish", .conflictPending):
            extras = ["conflictId", "conflictRevision", "head", "sourceGeneration"]
        case ("publish", _):
            extras = ["generation", "head", "snapshotId"]
        case ("resolveDevice", _):
            extras = ["conflictId", "conflictRevision", "generation", "head", "snapshotId"]
        case ("resolveServer", _):
            extras = [
                "conflictId", "conflictRevision", "head", "remoteGeneration",
                "remoteSnapshotId"
            ]
        case ("cloneWork", _):
            extras = [
                "conflictId", "conflictRevision", "head", "newRootSnapshotId",
                "newWorkId"
            ]
        case ("restore", _):
            extras = [
                "generation", "head", "protectedRestoreBeforeSnapshotId", "snapshotId"
            ]
        default:
            throw SyncV2StoreError.invalidAcknowledgement
        }
        try requireKeys(response, exactly: base.union(extras))
        guard try uuid(response, "commandId") == record.commandID,
              try string(response, "commandKind") == record.commandKind else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        let responseHead = response.keys.contains("head") ? try head(response["head"]) : nil
        try validateCommandResponseFields(
            response,
            record: record,
            payload: payload,
            result: result,
            head: responseHead
        )
        return responseHead
    }

    private func validateCommandResponseFields(
        _ response: [String: Any],
        record: V2SealedCommandRecord,
        payload: [String: Any],
        result: V2CommandTerminalResult,
        head: V2RemoteHead?
    ) throws {
        switch record.commandKind {
        case "createWork":
            guard head == nil,
                  try uuid(response, "workId").uuidString.lowercased() == record.workID.description,
                  try uuid(response, "documentId").uuidString.lowercased() == payload.uuid("documentId") else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case "prepareObject":
            if result == .applied {
                guard try string(response, "objectId") == payload.object("objectId").rawValue,
                      try (32 ... 2048).contains(string(response, "uploadCapability").count),
                      try UUID(uuidString: string(response, "uploadId")) != nil,
                      try ISO8601DateFormatter().date(from: string(response, "expiresAt")) != nil else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            }
        case "finalizeObject":
            guard head == nil,
                  try string(response, "objectId") == payload.object("objectId").rawValue,
                  try integer(response, "byteCount") == (payload["byteCount"] as? NSNumber)?.int64Value else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case "registerSnapshot":
            guard head == nil else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try requireSnapshot(response, key: "snapshotId", equals: payload.snapshot("snapshotId"))
        case "publish":
            if result == .conflictPending {
                guard head != nil,
                      try integer(response, "sourceGeneration") == record.sourceGeneration,
                      try integer(response, "conflictRevision") > 0,
                      try UUID(uuidString: string(response, "conflictId")) != nil else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            } else {
                try requireHeadFields(
                    response,
                    head: head,
                    expectedSnapshot: payload.snapshot("candidateSnapshotId")
                )
            }
        case "resolveDevice":
            try requireConflictFields(response, payload: payload)
            try requireHeadFields(
                response,
                head: head,
                expectedSnapshot: payload.snapshot("decisionSnapshotId")
            )
        case "resolveServer":
            try requireConflictFields(response, payload: payload)
            guard let head,
                  try string(response, "remoteSnapshotId") == payload.snapshot("remoteSnapshotId").rawValue,
                  try integer(response, "remoteGeneration") == head.generation,
                  try head.snapshotID == (payload.snapshot("remoteSnapshotId")) else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case "cloneWork":
            try requireConflictFields(response, payload: payload)
            guard let head,
                  try string(response, "newWorkId") == payload.uuid("newWorkId"),
                  try string(response, "newRootSnapshotId") == payload.snapshot("newRootSnapshotId").rawValue,
                  try head.snapshotID == (payload.snapshot("newRootSnapshotId")),
                  head.generation == 1 else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case "restore":
            try requireHeadFields(
                response,
                head: head,
                expectedSnapshot: payload.snapshot("newSnapshotId")
            )
            try requireSnapshot(
                response,
                key: "protectedRestoreBeforeSnapshotId",
                equals: record.sourceSnapshotID
            )
        default:
            break
        }
    }

    private func requireHeadFields(
        _ response: [String: Any],
        head: V2RemoteHead?,
        expectedSnapshot: SnapshotID
    ) throws {
        guard let head,
              head.snapshotID == expectedSnapshot,
              try string(response, "snapshotId") == head.snapshotID.rawValue,
              try integer(response, "generation") == head.generation else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }

    private func requireConflictFields(
        _ response: [String: Any],
        payload: [String: Any]
    ) throws {
        guard try string(response, "conflictId") == payload.uuid("conflictId"),
              try integer(response, "conflictRevision") ==
              (payload["conflictRevision"] as? NSNumber)?.int64Value else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }

    private func requireSnapshot(
        _ response: [String: Any],
        key: String,
        equals expected: SnapshotID
    ) throws {
        guard try string(response, key) == expected.rawValue else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }

    private func readBack(_ value: Any?) throws -> V2ReadBackPredicates {
        let value = try dictionary(value)
        try requireKeys(
            value,
            exactly: [
                "accountMatched", "commandDigestMatched", "headMatched",
                "resourceMatched", "stateMatched"
            ]
        )
        return try V2ReadBackPredicates(
            accountMatched: boolean(value, "accountMatched"),
            commandDigestMatched: boolean(value, "commandDigestMatched"),
            resourceMatched: boolean(value, "resourceMatched"),
            headMatched: boolean(value, "headMatched"),
            stateMatched: boolean(value, "stateMatched")
        )
    }

    private func head(_ value: Any?) throws -> V2RemoteHead? {
        if value is NSNull {
            return nil
        }
        let value = try dictionary(value)
        try requireKeys(value, exactly: ["generation", "snapshotId"])
        guard let generation = (value["generation"] as? NSNumber)?.int64Value else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: string(value, "snapshotId")),
            generation: generation
        )
    }

    private func strictJSONObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return object
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return value
    }

    private func requireKeys(
        _ dictionary: [String: Any],
        exactly keys: Set<String>
    ) throws {
        guard Set(dictionary.keys) == keys else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }

    private func string(_ dictionary: [String: Any], _ key: String) throws -> String {
        guard let value = dictionary[key] as? String else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return value
    }

    private func integer(_ dictionary: [String: Any], _ key: String) throws -> Int64 {
        guard let value = dictionary[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue == Double(value.int64Value),
              value.int64Value >= -V2RemoteHead.maximumGeneration,
              value.int64Value <= V2RemoteHead.maximumGeneration else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return value.int64Value
    }

    private func uuid(_ dictionary: [String: Any], _ key: String) throws -> UUID {
        guard let value = try UUID(uuidString: string(dictionary, key)),
              try value.uuidString.lowercased() == string(dictionary, key) else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return value
    }

    private func boolean(_ dictionary: [String: Any], _ key: String) throws -> Bool {
        guard let value = dictionary[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        return value.boolValue
    }
}

private extension Data {
    init?(strictBase64URL value: String) {
        guard !value.isEmpty,
              !value.contains("="),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              }) else { return nil }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded),
              decoded.base64URLEncodedString == value else { return nil }
        self = decoded
    }

    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
