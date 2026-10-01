import Foundation
import NovelSyncV2
import Testing

@Test func reportedPrepareObjectBytesAndRustReceiptWrapperAreAccepted() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SyncServerV2/tests/fixtures/prepare-object")
    let response = try Data(contentsOf: root.appendingPathComponent("applied.json"))
    let wrapper = try Data(contentsOf: root.appendingPathComponent("receipt.json"))
    #expect(response.count == 711)
    #expect(response.count % 3 == 0)
    let commandID = try #require(UUID(uuidString: "e629c41e-3d26-4fcf-9077-bf16e67c7b42"))
    let workID = try WorkID(uuidString: "76be6c87-8160-4ed5-b3d8-39912cdbfdbe")
    let digest = try ObjectID(rawValue: "bfd0a2c46bfec81080150d273a31945ebae2e802e965a111be8adbe5377694dc")
    for expectation in [SyncV2ReceiptExpectation.durable, .response(status: 201, result: "applied", canonicalBytes: response)] {
        let receipt = try validateSyncV2ReceiptEnvelope(
            wrapper, commandID: commandID, commandKind: "prepareObject", requestDigest: digest,
            workID: workID, expectation: expectation
        )
        #expect(receipt.canonicalResponse == response)
        #expect(receipt.responseStatus == 201)
        #expect(receipt.result == "applied")
    }
}
