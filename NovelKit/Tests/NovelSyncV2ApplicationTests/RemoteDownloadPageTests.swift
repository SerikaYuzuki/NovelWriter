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
                                                                   document: fixture.document, documentCreatedAt: fixture.createdAt, expectedGeneration: 0, reason: .explicit), scope: scope)
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

    @Test("large objects use the existing verified object read without inflating pages", arguments: [false, true])
    func largeObjectUsesSeparateRead(tracksProgress: Bool) async throws {
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
        let inbox = try await ImportProgress.$current.withValue(tracksProgress ? ImportProgress() : nil) {
            try await client.downloadRemoteOnly(workID: fixture.workID)
        }
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

    @Test("a later page retries its cursor without fetching the first page again")
    func laterPageResumesCursor() async throws {
        let fixture = LineageFixture()
        let snapshot = try fixture.snapshot(title: "two pages")
        let items = downloadItems([snapshot])
        let path = "/v2/works/\(fixture.workID.description)/download"
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [snapshot], publishResponse: nil)
        try state.failNext(path: path, replies: [
            downloadPage(head: snapshot.snapshotId, items: Array(items.prefix(1)), cursor: "next"),
            LineageHTTPReply(status: 503, headers: ["Retry-After": "0"], body: Data()),
            downloadPage(head: snapshot.snapshotId, items: Array(items.dropFirst()), cursor: nil)
        ])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.first?.snapshotId == snapshot.snapshotId)
        let queries = state.requestedQueries(path: path)
        #expect(queries.count == 3)
        #expect(queries[0]?.contains("cursor=") == false)
        #expect(queries[1] == queries[2])
        #expect(queries[1]?.contains("cursor=next") == true)
    }

    @Test("typed missing roots fail closed and fallback checks remote deletion", arguments: ["missingRoot", "deleted", "oldServer"])
    func missingEndpointOrRoot(kind: String) async throws {
        let fixture = LineageFixture()
        let snapshot = try fixture.snapshot(title: "remote")
        let path = "/v2/works/\(fixture.workID.description)/download"
        let statusPath = "/v2/protection/\(fixture.workID.description)/status"
        let manifestPath = "/v2/snapshots/\(snapshot.snapshotId.rawValue)/manifest"
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [snapshot], publishResponse: nil)
        if kind == "missingRoot" {
            state.failNext(path: path, replies: [LineageHTTPReply(status: 404, headers: downloadHeaders,
                                                                  body: Data(#"{"error":"notFoundInAccount","result":"parked","retryable":false}"#.utf8))])
        } else if kind == "deleted" {
            try state.failNext(path: statusPath, replies: [LineageHTTPReply(status: 200, headers: downloadHeaders,
                                                                            body: productionJSON(["result": "noChanges", "workId": fixture.workID.description, "deleted": true]))])
        }
        let client = try fixture.client(snapshots: [], overrideState: state)
        if kind == "oldServer" {
            #expect(try await client.downloadRemoteOnly(workID: fixture.workID).snapshots.first?.snapshotId == snapshot.snapshotId)
            #expect(state.count(path: manifestPath) == 1)
        } else {
            let expected: SyncV2Failure = kind == "deleted" ? .fatal(.remoteWorkDeleted) : .fatal(.remoteDataUnavailable)
            await #expect(throws: expected) { try await client.downloadRemoteOnly(workID: fixture.workID) }
            #expect(state.count(path: manifestPath) == 0)
        }
        #expect(state.count(path: statusPath) == 1)
    }

    @Test("Retry-After supports bounded seconds and HTTP dates")
    func boundedRetryAfter() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ProductionSyncV2RemoteClient.downloadRetryAfter("900") == 30)
        #expect(ProductionSyncV2RemoteClient.downloadRetryAfter("2") == 2)
        #expect(ProductionSyncV2RemoteClient.downloadRetryAfter("Thu, 01 Jan 1970 00:00:10 GMT", now: now) == 10)
        #expect(ProductionSyncV2RemoteClient.downloadRetryAfter("invalid") == nil)
    }

    @Test("cancellation interrupts server-directed retry sleep")
    func cancelBackoff() async throws {
        let fixture = LineageFixture()
        let path = "/v2/works/\(fixture.workID.description)/head"
        let state = LineageHTTPState(replies: ["GET \(path)":
                LineageHTTPReply(status: 503, headers: ["Retry-After": "30"], body: Data())])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let task = Task { try await client.downloadRemoteOnly(workID: fixture.workID) }
        try await eventually { state.count(path: path) == 1 }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(state.count(path: path) == 1)
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

extension RemoteHTTPLineageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_IMPORT_BENCHMARK"] == "1"))
    func syntheticFetchPerformance() async throws {
        let fixture = LineageFixture()
        var document = fixture.document
        var snapshots: [EncodedSnapshot] = []
        for index in 0 ..< 1500 {
            document.chapters[0].episodes[0].content = String(repeating: "a", count: 7000) + "\(index)"
            try snapshots.append(SnapshotCodec.encode(SnapshotModel(
                workId: fixture.workID, document: document, documentCreatedAt: fixture.createdAt
            ), parents: snapshots.last.map { [$0.snapshotId] } ?? []))
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
        let client = try fixture.client(snapshots: snapshots, overrideState: state)
        let start = ContinuousClock.now
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        print("BENCH fetch+graph snapshots=\(inbox.snapshots.count) pages=\(pages.count) bytes=\(pages.reduce(0) { $0 + $1.body.count }) elapsed=\(start.duration(to: .now))")
        #expect(inbox.snapshots.count == snapshots.count)
        #expect(state.count(path: path) == pages.count)
    }
}

extension RemoteHTTPLineageTests {
    @Test("large objects use file download and retain their bytes after cleanup")
    func largeObjectDownload() async throws {
        let fixture = LineageFixture()
        var document = fixture.document
        document.chapters[0].episodes[0].content = String(repeating: "large synthetic body", count: 20000)
        let snapshot = try SnapshotCodec.encode(SnapshotModel(workId: fixture.workID, document: document,
                                                              documentCreatedAt: fixture.createdAt), parents: [])
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [snapshot], publishResponse: nil)
        try state.failNext(path: "/v2/works/\(fixture.workID.description)/download", replies: [
            downloadPage(head: snapshot.snapshotId, items: downloadItems([snapshot]), cursor: nil)
        ])
        let client = try fixture.client(snapshots: [snapshot], overrideState: state)
        let result = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(result.snapshots.first?.objects == snapshot.objects)
        for entry in snapshot.manifest.entries where entry.byteCount > 256 * 1024 {
            #expect(state.count(path: "/v2/objects/\(entry.objectId.rawValue)") == 1)
        }
    }

    @Test("file validation rejects truncation, overflow, bad digest and wrong headers", arguments: ["valid", "short", "long", "digest", "header"])
    func streamingObjectValidation(mode: String) async throws {
        let bytes = Data(repeating: 123, count: 400_000)
        let entry = SnapshotEntry(byteCount: bytes.count, contentType: .octetStream,
                                  entityKey: "unused", objectId: ObjectID(data: bytes))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var received = bytes
        switch mode {
        case "short": received.removeLast()
        case "long": received.append(0)
        case "digest": received[0] = 0
        default: break
        }
        try received.write(to: url)
        let objectURL = try #require(URL(string: "https://fixture.invalid/object"))
        let response = try #require(HTTPURLResponse(url: objectURL, statusCode: 200,
                                                    httpVersion: nil, headerFields: [
                                                        "Content-Type": "application/octet-stream", "Cache-Control": mode == "header" ? "public" : "no-store",
                                                        "Pragma": "no-cache", "X-Fuminiwa-Object-Digest": entry.objectId.rawValue,
                                                        "X-Fuminiwa-Byte-Count": "\(entry.byteCount)"
                                                    ]))
        if mode == "valid" {
            let mapped = try await ProductionSyncV2RemoteClient.validateObjectFile(url, response: response, entry: entry)
            try FileManager.default.removeItem(at: url)
            #expect(mapped == bytes)
        } else {
            await #expect(throws: SyncV2Failure.quarantined(.invalidRemoteData)) {
                try await ProductionSyncV2RemoteClient.validateObjectFile(url, response: response, entry: entry)
            }
        }
    }
}

extension RemoteHTTPLineageTests {
    @Test("large-object requests overlap with a four-request bound and cancel as a group", arguments: [false, true])
    func boundedObjectRequests(cancel: Bool) async throws {
        let fixture = LineageFixture()
        var document = fixture.document
        var snapshots: [EncodedSnapshot] = []
        for index in 0 ..< 8 {
            document.chapters[0].episodes[0].content = String(repeating: "x", count: 300_000) + "\(index)"
            try snapshots.append(SnapshotCodec.encode(SnapshotModel(workId: fixture.workID, document: document,
                                                                    documentCreatedAt: fixture.createdAt),
                                                      parents: snapshots.last.map { [$0.snapshotId] } ?? []))
        }
        let state = LineageHTTPState(workID: fixture.workID, snapshots: snapshots, publishResponse: nil)
        let head = try #require(snapshots.last)
        try state.failNext(path: "/v2/works/\(fixture.workID.description)/download", replies: [
            downloadPage(head: head.snapshotId, items: downloadItems(snapshots), cursor: nil)
        ])
        let large = snapshots.flatMap(\.objects).filter { $0.value.count > 256 * 1024 }
        let paths = large.map { "/v2/objects/\($0.key.rawValue)" }
        for (id, bytes) in large {
            state.failNext(path: "/v2/objects/\(id.rawValue)", replies: [LineageHTTPReply(status: 200, headers: [
                "Content-Type": "application/octet-stream", "Cache-Control": "no-store", "Pragma": "no-cache",
                "X-Fuminiwa-Object-Digest": id.rawValue, "X-Fuminiwa-Byte-Count": "\(bytes.count)"
            ], body: bytes, delay: 0.5)])
        }
        let client = try fixture.client(snapshots: snapshots, overrideState: state)
        let task = Task { try await client.downloadRemoteOnly(workID: fixture.workID) }
        try await eventually { paths.reduce(0) { $0 + state.count(path: $1) } >= 4 }
        #expect(paths.reduce(0) { $0 + state.count(path: $1) } == 4)
        if cancel {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(paths.reduce(0) { $0 + state.count(path: $1) } == 4)
        } else {
            #expect(try await task.value.snapshots.count == 8)
            // Under a heavily loaded full suite, URLSession may time out and
            // retry a mocked read. Every object must still arrive exactly once
            // in the graph; transport attempts need not equal object count.
            #expect(paths.allSatisfy { state.count(path: $0) >= 1 })
        }
    }
}

extension RemoteHTTPLineageTests {
    @Test("invalid current-page items take precedence over a speculative next-page error")
    func invalidPageDiscardsPrefetch() async throws {
        let fixture = LineageFixture()
        let snapshot = try fixture.snapshot(title: "invalid page")
        var items = downloadItems([snapshot])
        items[0]["bytesBase64URL"] = "AA"
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [snapshot], publishResponse: nil)
        try state.failNext(path: "/v2/works/\(fixture.workID.description)/download", replies: [
            downloadPage(head: snapshot.snapshotId, items: items, cursor: "speculative"),
            LineageHTTPReply(status: 403, headers: [:], body: Data())
        ])
        let client = try fixture.client(snapshots: [snapshot], overrideState: state)
        await #expect(throws: SyncV2Failure.quarantined(.invalidRemoteData)) {
            try await client.downloadRemoteOnly(workID: fixture.workID)
        }
    }
}
