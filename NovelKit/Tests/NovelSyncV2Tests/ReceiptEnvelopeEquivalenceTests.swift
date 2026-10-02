import Foundation
@testable import NovelSyncV2
import Testing

struct ReceiptEnvelopeEquivalenceTests {
    @Test(arguments: ["valid", "extra", "commandId", "commandKind", "requestDigest", "workId", "result",
                      "originalResult", "originalResponseStatus", "canonicalResponseBase64URL", "false", "numeric"])
    func runtimeEnvelopeMatchesPreviousValidator(vector: String) throws {
        let commandID = UUID()
        let workID = WorkID(UUID())
        let digest = ObjectID(data: Data("command".utf8))
        let response = Data("{}".utf8)
        let predicates: [String: Bool] = ["accountMatched": true, "commandDigestMatched": true,
                                          "resourceMatched": true, "headMatched": true, "stateMatched": true]
        var value: [String: Any] = [
            "commandId": commandID.uuidString.lowercased(), "commandKind": "publish",
            "workId": workID.description, "requestDigest": digest.rawValue,
            "result": "noChanges", "originalResult": "applied", "originalResponseStatus": 200,
            "canonicalResponseBase64URL": "e30", "readBack": predicates
        ]
        switch vector {
        case "valid": break
        case "false": value["readBack"] = predicates.merging(["headMatched": false]) { _, new in new }
        case "numeric": value["readBack"] = predicates.mapValues { $0 ? 1 : 0 }
        case "originalResponseStatus": value[vector] = 201
        default: value[vector] = "wrong"
        }
        let serialized = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        let old = try legacyAccepts(serialized, commandID: commandID, workID: workID, digest: digest)
        let new = (try? validateSyncV2ReceiptEnvelope(
            serialized, commandID: commandID, commandKind: "publish", requestDigest: digest, workID: workID,
            expectation: .response(status: 200, result: "applied", canonicalBytes: response)
        )) != nil
        #expect(old == new)
    }

    /// Frozen pre-refactor runtime oracle. Store's stricter boolean rule is tested separately.
    private func legacyAccepts(_ data: Data, commandID: UUID, workID: WorkID, digest: ObjectID) throws -> Bool {
        try CanonicalJSON.validate(data)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(envelope.keys) == Set([
                  "canonicalResponseBase64URL", "commandId", "commandKind", "originalResponseStatus",
                  "originalResult", "readBack", "requestDigest", "result", "workId"
              ]),
              envelope["commandId"] as? String == commandID.uuidString.lowercased(),
              envelope["commandKind"] as? String == "publish",
              envelope["requestDigest"] as? String == digest.rawValue,
              envelope["workId"] as? String == workID.description,
              envelope["result"] as? String == "noChanges",
              envelope["originalResult"] as? String == "applied",
              envelope["originalResponseStatus"] as? Int == 200,
              envelope["canonicalResponseBase64URL"] as? String == "e30",
              let predicates = envelope["readBack"] as? [String: Bool],
              predicates == ["accountMatched": true, "commandDigestMatched": true, "resourceMatched": true,
                             "headMatched": true, "stateMatched": true] else { return false }
        return true
    }
}
