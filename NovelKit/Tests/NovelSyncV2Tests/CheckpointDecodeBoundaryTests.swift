import Foundation
import NovelCore
import NovelSyncV2
import Testing

@Test
func objectValidationDoesNotReplaceFullDecode() throws {
    let work = WorkID(UUID())
    let encoded = try SnapshotCodec.encode(SnapshotModel(
        workId: work,
        document: NovelDocument.newDocument(),
        documentCreatedAt: Date(timeIntervalSince1970: 0)
    ))
    let key = "work/document"
    let entry = try #require(encoded.manifest.entries.first { $0.entityKey == key })
    let old = try #require(encoded.objects[entry.objectId])
    let text = try #require(String(data: old, encoding: .utf8))
    let changed = Data(text.replacingOccurrences(of: "1970-01-01T00:00:00Z", with: "1970-99-99T99:99:99Z").utf8)
    var objects = encoded.objects
    objects.removeValue(forKey: entry.objectId)
    let id = ObjectID(data: changed)
    objects[id] = changed
    let entries = encoded.manifest.entries.map {
        $0.entityKey == key ? SnapshotEntry(
            byteCount: changed.count,
            contentType: $0.contentType,
            entityKey: key,
            objectId: id
        ) : $0
    }
    let manifest = SnapshotManifest(workId: work, entries: entries)
    let bytes = try CanonicalJSON.encode(manifest)
    let invalidDate = EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: objects)
    try SnapshotValidator.validateObjects(invalidDate)
    #expect(throws: (any Error).self) { try SnapshotCodec.decode(invalidDate) }
}
