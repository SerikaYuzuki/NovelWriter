import Foundation
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

extension RemoteHTTPLineageTests {
    @Test func interruptedUnclosedGroupIsReplayedAfterRestart() async throws {
        let fixture = try SharedShallowFixture()
        let http = LineageFixture(workID: fixture.workID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let head = try #require(fixture.snapshots.last)
        try await store.installShallowHead(V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: head.snapshotId,
                                                                 snapshots: [head], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                                                 expectedRemoteHead: V2RemoteHead(validatedSnapshotID: head.snapshotId, generation: 1)), scope: .bound(http.binding))
        var page = try #require(try JSONSerialization.jsonObject(with: fixture.backfillPage.body) as? [String: Any])
        let items = try #require(page["items"] as? [[String: Any]])
        let ancestor = fixture.snapshots[4]
        let cursorValue: [String: Any] = ["kind": "backfill", "accountId": http.binding.accountID,
                                          "accountFence": http.binding.accountFence, "serverInstanceId": http.binding.serverInstanceID,
                                          "protocolEpoch": 2, "workId": fixture.workID.description, "snapshotId": head.snapshotId.rawValue,
                                          "afterDepth": 4, "afterSnapshotId": ancestor.snapshotId.rawValue, "afterItem": 0]
        let cursor = try JSONSerialization.data(withJSONObject: cursorValue, options: [.sortedKeys, .withoutEscapingSlashes])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        page["items"] = [items[0]]
        page["nextCursor"] = cursor
        page["resumeCursor"] = NSNull()
        let split = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys, .withoutEscapingSlashes])
        let state = LineageHTTPState(workID: fixture.workID, snapshots: fixture.snapshots, publishResponse: nil)
        let path = "/v2/works/\(fixture.workID)/download?mode"
        state.failNext(path: path, replies: [.init(status: 200, headers: fixture.backfillPage.headers, body: split)] +
            Array(repeating: .init(status: 429, headers: [:], body: Data()), count: 6))
        let client = try http.client(snapshots: [], overrideState: state, localStore: store)
        await #expect(throws: (any Error).self) { try await client.backfillHistory(workID: fixture.workID) }
        #expect(try await store.backfillState(workID: fixture.workID)?.resumeCursor == nil)
        #expect(try await store.query("SELECT COUNT(*) FROM snapshots").first?[0].int64 == 1)
        await store.close()
        let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
        state.failNext(path: path, replies: [fixture.backfillPage])
        let resumed = try http.client(snapshots: [], overrideState: state, localStore: reopened)
        try await resumed.backfillHistory(workID: fixture.workID)
        #expect(try await reopened.backfillState(workID: fixture.workID)?.status == .complete)
        await reopened.close()
    }

    @Test(arguments: ["digest", "extraObject", "mode", "cursorKind"])
    func malformedBackfillWireAddsNoRows(kind: String) async throws {
        let fixture = try SharedShallowFixture()
        let http = LineageFixture(workID: fixture.workID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let head = try #require(fixture.snapshots.last)
        try await store.installShallowHead(V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: head.snapshotId,
                                                                 snapshots: [head], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                                                 expectedRemoteHead: V2RemoteHead(validatedSnapshotID: head.snapshotId, generation: 1)), scope: .bound(http.binding))
        var page = try #require(try JSONSerialization.jsonObject(with: fixture.backfillPage.body) as? [String: Any])
        var items = try #require(page["items"] as? [[String: Any]])
        switch kind {
        case "digest": items[0]["bytesBase64URL"] = "YmFk"
        case "extraObject":
            let extra = Data("extra".utf8)
            items.insert(["kind": "object", "id": ObjectID(data: extra).rawValue, "bytesBase64URL": "ZXh0cmE"], at: 0)
        case "mode": page["mode"] = "head"
        default: page["resumeCursor"] = "eyJraW5kIjoiaGVhZCJ9"
        }
        page["items"] = items
        let bytes = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys, .withoutEscapingSlashes])
        let state = LineageHTTPState(workID: fixture.workID, snapshots: fixture.snapshots, publishResponse: nil)
        state.failNext(path: "/v2/works/\(fixture.workID)/download?mode", replies: [.init(status: 200, headers: fixture.backfillPage.headers, body: bytes)])
        let client = try http.client(snapshots: [], overrideState: state, localStore: store)
        await #expect(throws: (any Error).self) { try await client.backfillHistory(workID: fixture.workID) }
        #expect(try await store.query("SELECT COUNT(*) FROM snapshots").first?[0].int64 == 1)
        #expect(try await store.backfillState(workID: fixture.workID)?.status == .failed)
        let requestCount = state.count(path: "/v2/works/\(fixture.workID)/download")
        try await client.backfillHistory(workID: fixture.workID)
        #expect(state.count(path: "/v2/works/\(fixture.workID)/download") == requestCount)
        #expect(try await client.backfillWorkIDs().isEmpty)
        state.failNext(path: "/v2/works/\(fixture.workID)/download?mode", replies: [fixture.backfillPage])
        try await client.backfillHistory(workID: fixture.workID, manual: true, progress: {})
        #expect(try await store.backfillState(workID: fixture.workID)?.status == .complete)
        await store.close()
    }
}
