import Foundation
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

private let shallowHeaders = ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache"]

extension RemoteHTTPLineageTests {
    @Test func sharedRustHeadAndBackfillInstallEndToEnd() async throws {
        let fixture = try SharedShallowFixture()
        let http = LineageFixture(workID: fixture.workID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let state = LineageHTTPState(workID: fixture.workID, snapshots: fixture.snapshots, publishResponse: nil)
        let path = "/v2/works/\(fixture.workID)/download"
        state.failNext(path: path + "?mode", replies: [fixture.headPage, fixture.backfillPage])
        let client = try http.client(snapshots: [], overrideState: state, localStore: store)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.shallow)
        #expect(inbox.snapshots.count == 1)
        let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: inbox.headSnapshotID,
                                          snapshots: inbox.snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(validatedSnapshotID: inbox.headSnapshotID, generation: 1))
        try await store.installShallowHead(graph, scope: .bound(http.binding))
        #expect(try await store.open(workID: fixture.workID, scope: .bound(http.binding)).document?.title == "Shallow fixture 5")
        try await client.backfillHistory(workID: fixture.workID)
        #expect(try await store.backfillState(workID: fixture.workID)?.status == .complete)
        for snapshot in fixture.snapshots {
            let local = try await store.committedSnapshot(workID: fixture.workID, snapshotID: snapshot.snapshotId, scope: .bound(http.binding))
            #expect(local?.manifestBytes == snapshot.manifestBytes)
            #expect(local?.objects == snapshot.objects)
        }
        #expect(state.requestedQueries(path: path).contains { $0?.contains("mode=backfill") == true })
        await store.close()
    }

    @Test(arguments: [400, 404, 405, 422])
    func oldServerModeRejectionUsesFullImport(status: Int) async throws {
        let fixture = LineageFixture()
        let base = try fixture.snapshot(title: "base")
        let head = try fixture.snapshot(title: "head", parents: [base.snapshotId])
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [base, head], publishResponse: nil)
        let path = "/v2/works/\(fixture.workID)/download"
        state.failNext(path: path + "?mode", replies: [LineageHTTPReply(status: status, headers: [:], body: Data())])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(!inbox.shallow)
        let receivedIDs = inbox.snapshots.map(\.snapshotId)
        #expect(receivedIDs == [base.snapshotId, head.snapshotId])
        #expect(state.requestedQueries(path: path).count(where: { $0?.contains("mode=head") == true }) == 1)
        #expect(state.requestedQueries(path: path).contains { $0?.contains("mode=") == false })
    }

    @Test(arguments: [401, 404])
    func backfillDeletionStatusSuspendsAndKeepsManuscript(status: Int) async throws {
        let fixture = try SharedShallowFixture()
        let http = LineageFixture(workID: fixture.workID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let head = try #require(fixture.snapshots.last)
        let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: head.snapshotId, snapshots: [head],
                                          expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(validatedSnapshotID: head.snapshotId, generation: 1))
        try await store.installShallowHead(graph, scope: .bound(http.binding))
        let state = LineageHTTPState(workID: fixture.workID, snapshots: fixture.snapshots, publishResponse: nil)
        state.failNext(path: "/v2/works/\(fixture.workID)/download?mode", replies: [.init(status: status, headers: [:], body: Data())])
        let client = try http.client(snapshots: [], overrideState: state, localStore: store)
        await #expect(throws: (any Error).self) { try await client.backfillHistory(workID: fixture.workID) }
        #expect(try await store.backfillState(workID: fixture.workID)?.status == .suspended)
        #expect(try await store.open(workID: fixture.workID, scope: .bound(http.binding)).document?.title == "Shallow fixture 5")
        await store.close()
    }

    @Test func originalRustTransportOnlyFixturesFailEntityValidation() async throws {
        let base = SharedShallowFixture.base
        for name in ["download-head-1", "download-backfill-1", "download-backfill-2"] {
            let bytes = try Data(contentsOf: base.appendingPathComponent("canonical/\(name).json"))
            let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let rawID = try #require(object["snapshotId"] as? String)
            let workID = try WorkID(uuidString: "10600000-0000-4000-8000-000000000001")
            let mode = name.contains("head") ? "head" : "backfill"
            let url = try #require(URL(string: "https://lineage.test"))
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                        httpVersion: nil, headerFields: shallowHeaders))
            let page = try await ProductionSyncV2RemoteClient.decodeDownloadPage(bytes, response: response,
                                                                                 id: SnapshotID(rawValue: rawID), allowsTotals: name.hasSuffix("1"), mode: mode)
            let containsManifest = page.items.contains { $0.objectDictionary?["kind"]?.stringContents == "manifest" }
            if containsManifest {
                await #expect(throws: (any Error).self) {
                    try await ProductionSyncV2RemoteClient.validatePageItems(page.items, workID: workID)
                }
            } else {
                let items = try await ProductionSyncV2RemoteClient.validatePageItems(page.items, workID: workID)
                #expect(!items.isEmpty)
            }
        }
    }
}

struct SharedShallowFixture {
    static var base: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/sync/v2/fixtures")
    }

    let workID: WorkID
    let snapshots: [EncodedSnapshot]
    let headPage: LineageHTTPReply
    let backfillPage: LineageHTTPReply

    init() throws {
        let bytes = try Data(contentsOf: Self.base.appendingPathComponent("scenarios/shallow-install-backfill.json"))
        let graph = try JSONDecoder().decode(Graph.self, from: bytes)
        let objects = try Dictionary(uniqueKeysWithValues: graph.objects.map { row in
            let bytes = try #require(Data(base64URL: row.bytesBase64URL))
            return (ObjectID(data: bytes), bytes)
        })
        snapshots = try graph.snapshots.map { row in
            let bytes = try #require(Data(base64URL: row.bytesBase64URL))
            let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
            let subset = try Dictionary(uniqueKeysWithValues: Set(manifest.entries.map(\.objectId)).map { id in
                let data = try #require(objects[id])
                return (id, data)
            })
            return EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: subset)
        }
        workID = try #require(snapshots.first).manifest.workId
        headPage = try .init(status: 200, headers: shallowHeaders, body: Data(contentsOf: Self.base.appendingPathComponent("canonical/install-head-1.json")))
        backfillPage = try .init(status: 200, headers: shallowHeaders, body: Data(contentsOf: Self.base.appendingPathComponent("canonical/install-backfill-1.json")))
    }

    private struct Graph: Decodable {
        let snapshots: [Row]
        let objects: [Row]
    }

    private struct Row: Decodable {
        let bytesBase64URL: String
    }
}
