import Foundation
import NovelCore
@testable import NovelSyncV2
import Testing

struct NovelSyncV2ConformanceTests {
    var canonical: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("docs/sync/v2/fixtures/canonical")
    }

    @Test func snapshotAndObjectHashesMatchFixtures() throws {
        let snapshotBytes = try Data(contentsOf: canonical.appendingPathComponent("snapshot.json"))
        let snapshotDigest = try String(
            contentsOf: canonical.appendingPathComponent("snapshot.sha256")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(SHA256Digest.hex(snapshotBytes) == snapshotDigest)
        let manifest = try SnapshotValidator.validate(manifestBytes: snapshotBytes)
        #expect(SnapshotID(data: snapshotBytes).rawValue == snapshotDigest)
        var objects: [ObjectID: Data] = [:]
        let hashBytes = try Data(
            contentsOf: canonical.appendingPathComponent("object-hashes.json")
        )
        let hashes = try #require(
            JSONSerialization.jsonObject(with: hashBytes) as? [String: Any]
        )
        for row in try #require(hashes["objects"] as? [[String: Any]]) {
            let fileName = try #require(row["file"] as? String)
            let data = try Data(
                contentsOf: canonical
                    .appendingPathComponent("objects")
                    .appendingPathComponent(fileName)
            )
            let id = try ObjectID(rawValue: #require(row["objectId"] as? String))
            let expectedByteCount = try #require(row["byteCount"] as? Int)
            objects[id] = data
            #expect(SHA256Digest.hex(data) == id.rawValue)
            #expect(data.count == expectedByteCount)
        }
        let encoded = EncodedSnapshot(manifest: manifest, manifestBytes: snapshotBytes, objects: objects)
        try SnapshotValidator.validateObjects(encoded)
        let model = try SnapshotCodec.decode(manifestBytes: snapshotBytes, objects: objects)
        let expectedBytes = try Data(
            contentsOf: canonical.appendingPathComponent("expected-model.json")
        )
        let expected = try #require(
            JSONSerialization.jsonObject(with: expectedBytes) as? [String: Any]
        )
        #expect(materialized(model).asNSDictionary.isEqual(to: expected))
        let reencoded = try SnapshotCodec.encode(model)
        #expect(reencoded.manifestBytes == snapshotBytes)

        var pollutedObjects = objects
        let unreferenced = Data("unreferenced".utf8)
        pollutedObjects[ObjectID(data: unreferenced)] = unreferenced
        let polluted = EncodedSnapshot(manifest: manifest, manifestBytes: snapshotBytes, objects: pollutedObjects)
        #expect(throws: Error.self) { try SnapshotValidator.validateObjects(polluted) }
    }

    @Test func allSealedCommandDigestsMatchFixtures() throws {
        let hashBytes = try Data(
            contentsOf: canonical.appendingPathComponent("command-hashes.json")
        )
        let hashes = try #require(
            JSONSerialization.jsonObject(with: hashBytes) as? [String: Any]
        )
        for row in try #require(hashes["commands"] as? [[String: Any]]) {
            let fileName = try #require(row["file"] as? String)
            let data = try Data(
                contentsOf: canonical.appendingPathComponent(fileName)
            )
            let command = try SealedCommand.decodeCanonical(data)
            let expectedDigest = try #require(row["requestDigest"] as? String)
            let expectedByteCount = try #require(row["byteCount"] as? Int)
            #expect(command.requestDigest.rawValue == expectedDigest)
            #expect(data.count == expectedByteCount)
        }
        let publish = try Data(contentsOf: canonical.appendingPathComponent("publish-command.json"))
        let publishCommand = try SealedCommand.decodeCanonical(publish)
        #expect(publishCommand.commandKind == "publish")
    }

    @Test func canonicalValidationFailsClosed() throws {
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"{"b":1,"a":2}"#.utf8)) }
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"{"a":1,"a":2}"#.utf8)) }
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"{"a":1.5}"#.utf8)) }
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"-9223372036854775808"#.utf8)) }
        let deeplyNested = String(repeating: "[", count: SnapshotSyncV2Limits.maxCanonicalJSONDepth + 1)
            + "0"
            + String(repeating: "]", count: SnapshotSyncV2Limits.maxCanonicalJSONDepth + 1)
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(deeplyNested.utf8)) }
        #expect(throws: Error.self) {
            try SnapshotValidator.validate(
                manifestBytes: Data(
                    repeating: 0x20,
                    count: SnapshotSyncV2Limits.maxManifestBytes + 1
                )
            )
        }
    }

    @Test func canonicalObjectKeysUseUTF16Order() {
        let data = CanonicalJSON.object([("\u{e000}", .number(1)), ("\u{1f600}", .number(2))])
        #expect(String(data: data, encoding: .utf8) == #"{"😀":2,"":1}"#)
    }

    @Test func manifestAndEntryObjectsAreClosed() throws {
        let snapshot = try String(contentsOf: canonical.appendingPathComponent("snapshot.json"))
        let topLevel = String(snapshot.dropLast()) + #","unexpected":1}"#
        #expect(throws: Error.self) { try SnapshotValidator.validate(manifestBytes: Data(topLevel.utf8)) }
        let entry = snapshot.replacingOccurrences(
            of: #""byteCount":3,"contentType"#,
            with: #""byteCount":3,"unexpected":1,"contentType"#,
            options: [],
            range: nil
        )
        #expect(throws: Error.self) { try SnapshotValidator.validate(manifestBytes: Data(entry.utf8)) }
    }

    @Test func strictUUIDAndEncodedManifestBinding() throws {
        let command = try Data(contentsOf: canonical.appendingPathComponent("publish-command.json"))
        let uppercase = try #require(
            String(data: command, encoding: .utf8)?.replacingOccurrences(
                of: "00000000-0000-4000-8000-000000000010",
                with: "00000000-0000-4000-8000-00000000001A"
            )
        )
        #expect(throws: Error.self) { try SealedCommand.decodeCanonical(Data(uppercase.utf8)) }

        let snapshotBytes = try Data(contentsOf: canonical.appendingPathComponent("snapshot.json"))
        let manifest = try SnapshotValidator.validate(manifestBytes: snapshotBytes)
        let changed = try #require(
            String(data: snapshotBytes, encoding: .utf8)?.replacingOccurrences(
                of: "00000000-0000-4000-8000-000000000002",
                with: "00000000-0000-4000-8000-000000000099"
            )
        )
        let encoded = EncodedSnapshot(manifest: manifest, manifestBytes: Data(changed.utf8), objects: [:])
        #expect(throws: Error.self) { try SnapshotValidator.validateObjects(encoded) }
    }
}
