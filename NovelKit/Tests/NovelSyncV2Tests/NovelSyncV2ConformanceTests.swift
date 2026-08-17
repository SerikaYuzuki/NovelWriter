import Foundation
@testable import NovelSyncV2
import Testing

struct NovelSyncV2ConformanceTests {
    private var canonical: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("docs/sync/v2/fixtures/canonical")
    }

    @Test func snapshotAndObjectHashesMatchFixtures() throws {
        let snapshotBytes = try Data(contentsOf: canonical.appendingPathComponent("snapshot.json"))
        let snapshotDigest = try String(contentsOf: canonical.appendingPathComponent("snapshot.sha256")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(SHA256Digest.hex(snapshotBytes) == snapshotDigest)
        let manifest = try SnapshotValidator.validate(manifestBytes: snapshotBytes)
        var objects: [ObjectID: Data] = [:]
        let hashes = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: canonical.appendingPathComponent("object-hashes.json"))) as? [String: Any])
        for row in try #require(hashes["objects"] as? [[String: Any]]) {
            let data = try Data(contentsOf: canonical.appendingPathComponent("objects").appendingPathComponent(#require(row["file"] as? String)))
            let id = try ObjectID(rawValue: #require(row["objectId"] as? String))
            objects[id] = data
            #expect(SHA256Digest.hex(data) == id.rawValue)
            #expect(data.count == row["byteCount"] as! Int)
        }
        let encoded = EncodedSnapshot(manifest: manifest, manifestBytes: snapshotBytes, objects: objects)
        try SnapshotValidator.validateObjects(encoded)
        let model = try SnapshotCodec.decode(manifestBytes: snapshotBytes, objects: objects)
        #expect(model.document.title == "三国志もの")
        #expect(model.document.chapters.first?.episodes.first?.content == "本文です。")
        #expect(model.attachments.first?.bytes == Data("map".utf8))
        let reencoded = try SnapshotCodec.encode(model)
        #expect(reencoded.manifestBytes == snapshotBytes)
    }

    @Test func allSealedCommandDigestsMatchFixtures() throws {
        let hashes = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: canonical.appendingPathComponent("command-hashes.json"))) as? [String: Any])
        for row in try #require(hashes["commands"] as? [[String: Any]]) {
            let data = try Data(contentsOf: canonical.appendingPathComponent(#require(row["file"] as? String)))
            let command = try SealedCommand.decodeCanonical(data)
            #expect(command.requestDigest.rawValue == row["requestDigest"] as! String)
            #expect(data.count == row["byteCount"] as! Int)
        }
        let publish = try Data(contentsOf: canonical.appendingPathComponent("publish-command.json"))
        let publishCommand = try SealedCommand.decodeCanonical(publish)
        #expect(publishCommand.commandKind == "publish")
    }

    @Test func canonicalValidationFailsClosed() throws {
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"{"b":1,"a":2}"#.utf8)) }
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"{"a":1,"a":2}"#.utf8)) }
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"{"a":1.5}"#.utf8)) }
    }
}
