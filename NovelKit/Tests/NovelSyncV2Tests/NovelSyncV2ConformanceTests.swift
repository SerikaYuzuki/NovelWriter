import Foundation
import NovelCore
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
        let expected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: canonical.appendingPathComponent("expected-model.json"))) as? [String: Any])
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
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(#"-9223372036854775808"#.utf8)) }
        let deeplyNested = String(repeating: "[", count: SnapshotSyncV2Limits.maxCanonicalJSONDepth + 1)
            + "0"
            + String(repeating: "]", count: SnapshotSyncV2Limits.maxCanonicalJSONDepth + 1)
        #expect(throws: Error.self) { try CanonicalJSON.validate(Data(deeplyNested.utf8)) }
        #expect(throws: Error.self) {
            try SnapshotValidator.validate(manifestBytes: Data(repeating: 0x20, count: SnapshotSyncV2Limits.maxManifestBytes + 1))
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
        let entry = snapshot.replacingOccurrences(of: #""byteCount":3,"contentType"#, with: #""byteCount":3,"unexpected":1,"contentType"#, options: [], range: nil)
        #expect(throws: Error.self) { try SnapshotValidator.validate(manifestBytes: Data(entry.utf8)) }
    }

    @Test func strictUUIDAndEncodedManifestBinding() throws {
        let command = try Data(contentsOf: canonical.appendingPathComponent("publish-command.json"))
        let uppercase = try #require(String(data: command, encoding: .utf8)?.replacingOccurrences(of: "00000000-0000-4000-8000-000000000010", with: "00000000-0000-4000-8000-00000000001A"))
        #expect(throws: Error.self) { try SealedCommand.decodeCanonical(Data(uppercase.utf8)) }

        let snapshotBytes = try Data(contentsOf: canonical.appendingPathComponent("snapshot.json"))
        let manifest = try SnapshotValidator.validate(manifestBytes: snapshotBytes)
        let changed = try #require(String(data: snapshotBytes, encoding: .utf8)?.replacingOccurrences(of: "00000000-0000-4000-8000-000000000002", with: "00000000-0000-4000-8000-000000000099"))
        let encoded = EncodedSnapshot(manifest: manifest, manifestBytes: Data(changed.utf8), objects: [:])
        #expect(throws: Error.self) { try SnapshotValidator.validateObjects(encoded) }
    }

    private func materialized(_ model: SnapshotModel) -> [String: Any] {
        func chapter(_ chapter: NovelCore.Chapter) -> [String: Any] {
            ["id": chapter.id.rawValue.uuidString.lowercased(), "title": chapter.title, "episodes": chapter.episodes.map { episode in
                ["id": episode.id.rawValue.uuidString.lowercased(), "title": episode.title, "content": episode.content, "memo": episode.memo]
            }]
        }
        func character(_ character: NovelCore.Character) -> [String: Any] {
            ["id": character.id.rawValue.uuidString.lowercased(), "name": character.name, "kana": character.kana, "memo": character.memo, "colorHex": jsonValue(character.colorHex), "role": jsonValue(character.role), "age": jsonValue(character.age), "gender": jsonValue(character.gender), "firstPerson": jsonValue(character.firstPerson), "secondPerson": jsonValue(character.secondPerson), "speechStyle": jsonValue(character.speechStyle), "appearance": jsonValue(character.appearance), "personality": jsonValue(character.personality), "background": jsonValue(character.background)]
        }
        return ["schemaVersion": 2, "workId": model.workId.description, "document": ["id": model.document.id.uuidString.lowercased(), "documentCreatedAt": isoString(model.documentCreatedAt), "title": model.document.title, "synopsis": model.document.synopsis, "chapters": model.document.chapters.map(chapter), "characters": model.document.characters.map(character), "plotCards": model.document.plotCards.map { ["id": $0.id.rawValue.uuidString.lowercased(), "title": $0.title, "memo": $0.memo, "chapterId": jsonValue($0.chapterID?.rawValue.uuidString.lowercased())] }, "flags": model.document.flags.map { ["id": $0.id.rawValue.uuidString.lowercased(), "title": $0.title, "note": $0.note, "isResolved": $0.isResolved, "plantedChapterId": jsonValue($0.plantedChapterID?.rawValue.uuidString.lowercased()), "resolvedChapterId": jsonValue($0.resolvedChapterID?.rawValue.uuidString.lowercased())] }, "worldNotes": model.document.worldNotes.map { ["id": $0.id.rawValue.uuidString.lowercased(), "title": $0.title, "content": $0.content] }], "attachments": model.attachments.map { ["attachmentId": $0.attachmentId.uuidString.lowercased(), "fileName": $0.fileName, "byteCount": $0.byteCount, "objectId": $0.objectId.rawValue] }]
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private func jsonValue(_ value: String?) -> Any {
        value ?? NSNull()
    }
}

private extension [String: Any] {
    var asNSDictionary: NSDictionary {
        NSDictionary(dictionary: self)
    }
}
