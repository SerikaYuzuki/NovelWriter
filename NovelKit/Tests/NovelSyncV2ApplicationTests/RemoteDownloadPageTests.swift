import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

extension RemoteHTTPLineageTests {
    @Test("a complete page graph is not truncated by a previously committed local ancestor")
    func downloadedGraphKeepsItsLocalAncestors() async throws {
        let fixture = LineageFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let scope = V2LocalWorkScope.bound(fixture.binding)
        let saved = try await store.checkpoint(V2CheckpointRequest(workID: fixture.workID,
                                                                   document: fixture.document, documentCreatedAt: fixture.createdAt, expectedGeneration: 0), scope: scope)
        let base = try fixture.snapshot(title: "B")
        #expect(saved.snapshotID == base.snapshotId)
        let head = try fixture.snapshot(title: "remote", parents: [base.snapshotId])
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [base, head], publishResponse: nil)
        try state.failNext(path: "/v2/works/\(fixture.workID.description)/download", replies: [
            downloadPage(head: head.snapshotId, items: downloadItems([base, head]), cursor: nil)
        ])
        let client = try fixture.client(snapshots: [], overrideState: state, localStore: store)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.map(\.snapshotId) == [base.snapshotId, head.snapshotId])
        #expect(try await store.open(workID: fixture.workID, scope: scope).summary.currentSnapshotID == saved.snapshotID)
        await store.close()
    }

    @Test("cold history uses bounded pages instead of one HTTP request per version and object")
    func coldHistoryUsesDownloadPages() async throws {
        let fixture = LineageFixture()
        var snapshots: [EncodedSnapshot] = []
        for index in 0 ..< 512 {
            try snapshots.append(fixture.snapshot(title: "version-\(index)", parents: snapshots.last.map { [$0.snapshotId] } ?? []))
        }
        let head = try #require(snapshots.last)
        let items = downloadItems(snapshots)
        let pages = try stride(from: 0, to: items.count, by: 256).map { offset in
            try downloadPage(head: head.snapshotId, items: Array(items[offset ..< min(offset + 256, items.count)]),
                             cursor: offset + 256 < items.count ? "page-\(offset + 256)" : nil)
        }
        let state = LineageHTTPState(workID: fixture.workID, snapshots: snapshots, publishResponse: nil)
        let path = "/v2/works/\(fixture.workID.description)/download"
        state.failNext(path: path, replies: pages)
        let client = try fixture.client(snapshots: [], overrideState: state)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.map(\.snapshotId) == snapshots.map(\.snapshotId))
        #expect(state.count(path: path) == pages.count)
        #expect(pages.count < 10)
        for snapshot in snapshots {
            #expect(state.count(path: "/v2/snapshots/\(snapshot.snapshotId.rawValue)/manifest") == 0)
            for object in snapshot.objects.keys {
                #expect(state.count(path: "/v2/objects/\(object.rawValue)") == 0)
            }
        }
    }

    @Test("invalid or incomplete pages never fall back to individual reads", arguments: ["digest", "parent", "object", "head", "cursor", "scope"])
    func invalidDownloadPageFailsClosed(failure: String) async throws {
        let fixture = LineageFixture()
        let base = try fixture.snapshot(title: "base")
        let head = try fixture.snapshot(title: "head", parents: [base.snapshotId])
        var items = downloadItems([base, head])
        var responseHead = head.snapshotId
        switch failure {
        case "digest": items[0]["bytesBase64URL"] = Data("invalid".utf8).downloadBase64
        case "parent": items.removeAll { $0["kind"] == "manifest" && $0["id"] == base.snapshotId.rawValue }
        case "object": items.removeAll { $0["kind"] == "object" }
        case "head": responseHead = base.snapshotId
        default: break
        }
        let first = try downloadPage(head: responseHead, items: items, cursor: failure == "cursor" ? "repeated" : nil)
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [base, head], publishResponse: nil)
        let path = "/v2/works/\(fixture.workID.description)/download"
        state.failNext(path: path, replies: failure == "scope"
            ? [LineageHTTPReply(status: 403, headers: [:], body: Data())] : [first, first])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let expected: SyncV2Failure = failure == "scope" ? .accountFenceChanged : .quarantined(.invalidRemoteData)
        await #expect(throws: expected) { try await client.downloadRemoteOnly(workID: fixture.workID) }
        #expect(state.count(path: path) == (failure == "cursor" ? 2 : 1))
        #expect(state.count(path: "/v2/snapshots/\(head.snapshotId.rawValue)/manifest") == 0)
    }

    @Test("large objects use the existing verified object read without inflating pages")
    func largeObjectUsesSeparateRead() async throws {
        let fixture = LineageFixture()
        var document = fixture.document(title: "large content")
        document.chapters[0].episodes[0].content = String(repeating: "a", count: 300_000)
        let snapshot = try SnapshotCodec.encode(SnapshotModel(workId: fixture.workID, document: document,
                                                              documentCreatedAt: fixture.createdAt))
        let large = try #require(snapshot.objects.first { $0.value.count > 256 * 1024 }?.key)
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [snapshot], publishResponse: nil)
        try state.failNext(path: "/v2/works/\(fixture.workID.description)/download", replies: [
            downloadPage(head: snapshot.snapshotId, items: downloadItems([snapshot]), cursor: nil)
        ])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.first?.objects[large] == snapshot.objects[large])
        #expect(state.count(path: "/v2/objects/\(large.rawValue)") == 1)
    }

    @Test("the shared server page fixture passes the client digest and closure checks")
    func sharedDownloadPageFixture() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/sync/v2/fixtures/canonical/download-page.json")
        let data = try Data(contentsOf: fixtureURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let head = try SnapshotID(rawValue: #require(object["snapshotId"] as? String))
        let items = try #require(object["items"] as? [[String: String]])
        let manifestItem = try #require(items.first { $0["kind"] == "manifest" })
        let raw = try #require(manifestItem["bytesBase64URL"])
        let bytes = try #require(Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - raw.count % 4) % 4)))
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        let fixture = LineageFixture()
        let path = "/v2/works/\(manifest.workId.description)/download"
        let state = LineageHTTPState(replies: ["GET \(path)": LineageHTTPReply(status: 200, headers: downloadHeaders, body: data)])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let batch = try await client.downloadSnapshotPages(workID: manifest.workId, id: head, session: client.loadSession())
        #expect(batch?.manifests.count == 1)
        #expect(batch?.objects.count == Set(manifest.entries.map(\.objectId)).count)
    }
}

private let downloadHeaders = ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache"]

private func downloadPage(head: SnapshotID, items: [[String: String]], cursor: String?) throws -> LineageHTTPReply {
    try LineageHTTPReply(status: 200, headers: downloadHeaders,
                         body: productionJSON(["result": "noChanges", "snapshotId": head.rawValue,
                                               "items": items, "nextCursor": cursor as Any? ?? NSNull()]))
}

private func downloadItems(_ snapshots: [EncodedSnapshot]) -> [[String: String]] {
    var objects: [ObjectID: Data] = [:]
    let manifests = snapshots.map { snapshot in
        objects.merge(snapshot.objects, uniquingKeysWith: { first, _ in first })
        return ["kind": "manifest", "id": snapshot.snapshotId.rawValue, "bytesBase64URL": snapshot.manifestBytes.downloadBase64]
    }.sorted { $0["id"]! < $1["id"]! }
    return manifests + objects.filter { $0.value.count <= 256 * 1024 }.map {
        ["kind": "object", "id": $0.key.rawValue, "bytesBase64URL": $0.value.downloadBase64]
    }.sorted { $0["id"]! < $1["id"]! }
}

private extension Data {
    var downloadBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
