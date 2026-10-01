import CoreFoundation
import Foundation

public enum SyncV2ReceiptValidationError: Error {
    case mismatch
}

/// A transport readback compares the exact response already received. Durable
/// acknowledgement additionally requires JSON booleans (the original Store rule).
public enum SyncV2ReceiptExpectation: Sendable {
    case durable
    case response(status: Int, result: String, canonicalBytes: Data)
}

public struct SyncV2ValidatedReceiptEnvelope: Sendable {
    public let responseStatus: Int
    public let result: String
    public let canonicalResponse: Data
}

/// Pure envelope validation shared by the transport and the durable store.
/// Body/head validation belongs to each caller's existing response boundary.
public func validateSyncV2ReceiptEnvelope(
    _ data: Data,
    commandID: UUID,
    commandKind: String,
    requestDigest: ObjectID,
    workID: WorkID,
    expectation: SyncV2ReceiptExpectation
) throws -> SyncV2ValidatedReceiptEnvelope {
    try CanonicalJSON.validate(data)
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(envelope.keys) == Set([
              "canonicalResponseBase64URL", "commandId", "commandKind", "originalResponseStatus",
              "originalResult", "readBack", "requestDigest", "result", "workId"
          ]),
          envelope["commandId"] as? String == commandID.uuidString.lowercased(),
          envelope["commandKind"] as? String == commandKind,
          envelope["requestDigest"] as? String == requestDigest.rawValue,
          envelope["workId"] as? String == workID.description,
          envelope["result"] as? String == "noChanges",
          let result = envelope["originalResult"] as? String,
          let status = envelope["originalResponseStatus"] as? Int,
          let encoded = envelope["canonicalResponseBase64URL"] as? String,
          !encoded.isEmpty, let response = Data(base64URL: encoded),
          let predicates = envelope["readBack"] as? [String: Bool],
          predicates == [
              "accountMatched": true, "commandDigestMatched": true, "resourceMatched": true,
              "headMatched": true, "stateMatched": true
          ] else {
        throw SyncV2ReceiptValidationError.mismatch
    }
    switch expectation {
    case .durable:
        guard let number = envelope["originalResponseStatus"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.int64Value),
              abs(number.int64Value) <= 9_007_199_254_740_991,
              let values = envelope["readBack"] as? [String: NSNumber],
              values.values.allSatisfy({ CFGetTypeID($0) == CFBooleanGetTypeID() }) else {
            throw SyncV2ReceiptValidationError.mismatch
        }
    case let .response(expectedStatus, expectedResult, expectedBytes):
        guard status == expectedStatus, result == expectedResult, response == expectedBytes else {
            throw SyncV2ReceiptValidationError.mismatch
        }
    }
    return SyncV2ValidatedReceiptEnvelope(responseStatus: status, result: result, canonicalResponse: response)
}
