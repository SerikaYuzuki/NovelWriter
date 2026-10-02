import Foundation
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

extension RemoteHTTPLineageTests {
    @Test("mixed attachment windows retain every result with task-local progress", arguments: [false, true])
    func attachmentWindowResults(tracksProgress: Bool) async throws {
        let fixture = LineageFixture()
        let payloads = (0 ..< 9).map { index in
            Data(repeating: UInt8(index), count: index.isMultiple(of: 2) ? 300_000 : 1024)
        }
        let entries = payloads.enumerated().map { index, bytes in
            SnapshotEntry(byteCount: bytes.count, contentType: .octetStream,
                          entityKey: "attachment/cover-\(index)", objectId: ObjectID(data: bytes))
        }
        let replies = Dictionary(uniqueKeysWithValues: zip(entries, payloads).enumerated().map { index, pair in
            let (entry, bytes) = pair
            return ("GET /v2/objects/\(entry.objectId.rawValue)", LineageHTTPReply(status: 200, headers: [
                "Content-Type": "application/octet-stream", "Cache-Control": "no-store", "Pragma": "no-cache",
                "X-Fuminiwa-Object-Digest": entry.objectId.rawValue, "X-Fuminiwa-Byte-Count": "\(bytes.count)"
            ], body: bytes, delay: Double(4 - index % 4) * 0.005))
        })
        let state = LineageHTTPState(replies: replies)
        let client = try fixture.client(snapshots: [], overrideState: state)
        let session = try await client.loadSession()
        for _ in 0 ..< 10 {
            let progress = tracksProgress ? ImportProgress() : nil
            let objects = try await ImportProgress.$current.withValue(progress) {
                try await client.fetchObjects(entries: entries, session: session, traversal: SnapshotFetchTraversal())
            }
            #expect(!Task.isCancelled)
            #expect(objects.count == entries.count)
            for (entry, bytes) in zip(entries, payloads) {
                #expect(objects[entry.objectId] == bytes)
            }
            if let progress {
                #expect(progress.value.receivedBytes == payloads.reduce(0) { $0 + Int64($1.count) })
            }
        }
    }

    @Test("object errors retain manifest order even when a later request fails first")
    func objectWindowFailureOrder() async throws {
        let fixture = LineageFixture()
        let entries = (0 ..< 4).map { index in
            SnapshotEntry(byteCount: 300_000, contentType: .octetStream,
                          entityKey: "attachment/\(index)", objectId: ObjectID(data: Data([UInt8(index)])))
        }
        let replies = Dictionary(uniqueKeysWithValues: entries.enumerated().map { index, entry in
            ("GET /v2/objects/\(entry.objectId.rawValue)", LineageHTTPReply(
                status: index == 0 ? 403 : 404, headers: [:], body: Data(), delay: index == 0 ? 0.05 : 0
            ))
        })
        let client = try fixture.client(snapshots: [], overrideState: LineageHTTPState(replies: replies))
        let session = try await client.loadSession()
        await #expect(throws: SyncV2Failure.accountFenceChanged) {
            try await client.fetchObjects(entries: entries, session: session, traversal: SnapshotFetchTraversal())
        }
    }
}
