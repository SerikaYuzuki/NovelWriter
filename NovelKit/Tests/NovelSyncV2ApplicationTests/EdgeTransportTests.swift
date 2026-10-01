import Foundation
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

extension RemoteHTTPLineageTests {
    @Test(arguments: [408, 429, 500, 502, 503, 504] + Array(520 ... 530) + [401, 403, 200, 201, 409, 422])
    func edgeStatusPrecedesOriginHeaders(status: Int) async throws {
        let fixture = LineageFixture()
        let snapshot = try fixture.snapshot(title: "edge")
        let command = try fixture.publishCommand(source: snapshot, expectedRemoteHead: .init(snapshotID: snapshot.snapshotId, generation: 1))
        let client = try fixture.client(snapshots: [])
        let url = try #require(URL(string: "https://fixture.invalid"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/html"]))
        let bytes = Data("<html>Cloudflare: Bad Gateway</html>".utf8)
        let expected: SyncV2Failure = switch status {
        case 401: .authenticationRequired
        case 403: .accountFenceChanged
        case 408, 429, 500 ... 599: .retryable(.serverUnavailable)
        default: .receiptMismatch
        }
        await #expect(throws: expected) { try await client.decode(data: bytes, response: response, command: command) }
        let downloadExpected: SyncV2Failure = [200, 201, 409, 422].contains(status) ? .quarantined(.invalidRemoteData) : expected
        await #expect(throws: downloadExpected) {
            try await ProductionSyncV2RemoteClient.decodeDownloadPage(bytes, response: response, id: snapshot.snapshotId, allowsTotals: false)
        }
        let entry = SnapshotEntry(byteCount: 3, contentType: .octetStream, entityKey: "fixture", objectId: ObjectID(data: Data("abc".utf8)))
        #expect(throws: downloadExpected) { try ProductionSyncV2RemoteClient.validateObjectHeaders(response, entry: entry) }
    }
}

extension RemoteHTTPLineageTests {
    @Test(arguments: ["commandIdReused", "futureUploadError", "uploadExpired"], [false, true])
    func typedFinalize409RetainsRetry(code: String, headersValid: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let command = try SealedCommand.decodeCanonical(Data(contentsOf: root.appendingPathComponent("docs/sync/v2/fixtures/canonical/commands/finalize-object.json")))
        let client = try LineageFixture().client(snapshots: [])
        let url = try #require(URL(string: "https://fixture.invalid/v2/objects/finalize"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: headersValid
                ? ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache"] : [:]))
        let bytes = try productionJSON(["error": code, "result": "parked", "retryable": false])
        let expected: SyncV2Failure = headersValid
            ? .retryable(code == "uploadExpired" ? .uploadExpired : .serverUnavailable) : .receiptMismatch
        await #expect(throws: expected) { try await client.decode(data: bytes, response: response, command: command) }
    }
}
