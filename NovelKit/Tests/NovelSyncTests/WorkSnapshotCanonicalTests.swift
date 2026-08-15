// Canonical corruption fixtures are intentionally expressed as exact one-line byte strings.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable line_length optional_data_string_conversion
import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("Work snapshot canonical wire")
struct WorkSnapshotCanonicalTests {
    @Test("all NovelDocument fields round-trip without device-only state")
    func allFieldsRoundTrip() throws {
        let document = WorkTestValues.fullDocument()
        let snapshot = try WorkSnapshot(document: document)
        let data = try WorkCanonicalJSON.encodeSnapshot(snapshot)

        #expect(data.count < WorkSnapshot.maximumCanonicalByteCount)
        #expect(try WorkCanonicalJSON.decodeSnapshot(data) == snapshot)
        #expect(try snapshot.materializedDocument() == document)
        #expect(snapshot.episodes.first?.content == "one\ntwo\nthree")
        #expect(snapshot.episodes.first?.memo == "話メモ")
        #expect(snapshot.worldNotes.first?.content == "世界観本文")
        #expect(snapshot.characters.first?.background == "地球出身")
    }

    @Test("canonical snapshot decode rejects pretty, unknown, and duplicate JSON members")
    func rejectsNonCanonicalJSON() throws {
        let canonical = try WorkCanonicalJSON.encodeSnapshot(WorkTestValues.snapshot())
        let object = try JSONSerialization.jsonObject(with: canonical)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        #expect(throws: WorkSnapshotError.self) {
            _ = try WorkCanonicalJSON.decodeSnapshot(pretty)
        }

        let text = String(decoding: canonical, as: UTF8.self)
        let unknown = Data(text.replacingOccurrences(of: "{", with: "{\"future\":1,", options: [], range: text.startIndex ..< text.index(after: text.startIndex)).utf8)
        #expect(throws: WorkSnapshotError.self) {
            _ = try WorkCanonicalJSON.decodeSnapshot(unknown)
        }

        let duplicate = Data(text.replacingOccurrences(of: "{", with: "{\"title\":\"duplicate\",", options: [], range: text.startIndex ..< text.index(after: text.startIndex)).utf8)
        #expect(throws: WorkSnapshotError.self) {
            _ = try WorkCanonicalJSON.decodeSnapshot(duplicate)
        }
    }

    @Test("revision canonical wire fixes digest, byte count, timestamp, and work protocol v1")
    func revisionRoundTrip() throws {
        let revision = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot(),
            id: "70000000-0000-0000-0000-000000000001"
        )
        let data = try WorkCanonicalJSON.encodeRevision(revision)
        let decoded = try WorkCanonicalJSON.decodeRevision(data)
        let snapshotByteCount = try WorkCanonicalJSON.encodeSnapshot(decoded.snapshot).count

        #expect(decoded == revision)
        #expect(decoded.snapshotByteCount == snapshotByteCount)
        #expect(String(decoding: data, as: UTF8.self).contains("\"protocolVersion\":1"))
        #expect(data.count < WorkRevision.maximumCanonicalByteCount)
    }

    @Test("resource caps are whole-work sized while individual fields remain bounded")
    func resourceCaps() {
        #expect(WorkSnapshot.maximumCanonicalByteCount >= 32 * 1024 * 1024)
        #expect(WorkSnapshot.maximumCanonicalByteCount == 48 * 1024 * 1024)
        #expect(WorkRevision.maximumCanonicalByteCount > WorkSnapshot.maximumCanonicalByteCount)
        #expect(WorkFieldConflict.maximumValueUTF8Bytes <= 4 * 1024)
    }

    @Test("conflict descriptors retain bounded excerpt and digest, not four full manuscripts")
    func conflictDescriptorIsBounded() throws {
        let huge = String(repeating: "本文", count: 10000)
        let conflict = WorkFieldConflict(
            path: "episodes.value.content",
            entityKind: .episode,
            entityID: nil,
            field: "content",
            reason: .textOverlap,
            baseValue: huge,
            localValue: huge,
            remoteValue: huge,
            proposedValue: huge
        )
        try conflict.validate()
        #expect(conflict.baseValue?.utf8.count ?? 0 <= WorkFieldConflict.maximumValueUTF8Bytes)
        #expect(conflict.baseValue?.contains("sha256:") == true)
    }
}
