import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

/// The same test also runs against HEAD's unmodified store in a temporary,
/// minimal package. Only independently generated occurrence UUIDs/times are
/// normalized. IDs, payload/manifest bytes and the tested durable projections are exact.
@Test(.serialized, arguments: [(1000, 1), (100_000, 100), (300_000, 150), (1_000_000, 300)], [false, true])
func checkpointRowParity(size: (Int, Int), attached: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-parity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(parityUUID(1))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let episodes = (0 ..< size.1).map {
        Episode(id: EpisodeID(rawValue: parityUUID(100 + $0)), title: "話\($0)",
                content: String(repeating: "文", count: size.0 / size.1))
    }
    let chapter = Chapter(id: ChapterID(rawValue: parityUUID(3)), title: "章", episodes: episodes)
    var doc = NovelDocument(id: parityUUID(2), title: "合成", chapters: [chapter])
    let attachment = SyncAttachment(attachmentId: parityUUID(4), fileName: "test.bin", bytes: Data([0, 1, 255]))
    let resources = attached ? [PortableResource(pathComponents: ["opaque.bin"],
                                                 kind: .regularFile,
                                                 bytes: Data([2, 3]))] : []
    var generation: Int64 = 0
    var resultIDs: [String] = []
    for step in 0 ..< 5 {
        if step == 1 || step == 4 {
            doc.chapters[0].episodes[0].content += "字"
        }
        let result = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                                    document: doc,
                                                                    documentCreatedAt: date,
                                                                    expectedGeneration: generation,
                                                                    reason: step == 3 || step == 4 ? .explicit :
                                                                        .autosave,
                                                                    attachments: attached ? [attachment] : [],
                                                                    resources: resources),
                                                scope: .unbound)
        generation = result.generation
        resultIDs.append("\(result.snapshotID):\(result.generation):\(result.noChanges):\(result.promotedLeaf)")
    }
    var rows = try await store.parityRows()
    rows["results"] = [resultIDs]
    try assertParityReference(rows, size: size, attached: attached)
    #expect(try await store.open(workID: work, scope: .unbound).document == doc)
    await store.close()
}

private func assertParityReference(_ rows: [String: [[String]]], size: (Int, Int), attached: Bool) throws {
    if let directory = ProcessInfo.processInfo.environment["FUMINIWA_CHECKPOINT_PARITY"] {
        let path = URL(fileURLWithPath: directory).appendingPathComponent("\(size.0)-\(size.1)-\(attached).json")
        if ProcessInfo.processInfo.environment["FUMINIWA_CHECKPOINT_PARITY_WRITE"] == "1" {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(rows).write(to: path)
        } else {
            let original = try JSONDecoder().decode([String: [[String]]].self, from: Data(contentsOf: path))
            #expect(rows == original)
        }
    }
}

private func parityUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

private extension LocalSyncV2Store {
    func parityRows() throws -> [String: [[String]]] {
        var result: [String: [[String]]] = [:]
        for table in ["objects", "snapshots", "snapshot_entries", "snapshot_parents", "works", "history_occurrences",
                      "sync_intents", "work_resources", "resources"] {
            let columns = try query("PRAGMA table_info(\(table))").compactMap { try $0.text("name") }
            if columns.isEmpty {
                continue
            }
            result[table] = try query("SELECT * FROM \(table) ORDER BY rowid").map { row in
                try columns.map { column in
                    let value = try row.value(named: column)
                    if column == "occurrence_id" || column == "intent_id" {
                        return "<generated-id>"
                    }
                    if column != "document_created_at", column.hasSuffix("_at"), case .text = value {
                        return "<clock>"
                    }
                    return switch value {
                    case .null: "null"
                    case let .text(text): "text:" + text
                    case let .int(number): "int:\(number)"
                    case let .blob(data): "blob:" + data.base64EncodedString()
                    }
                }
            }.sorted { $0.lexicographicallyPrecedes($1) }
        }
        return result
    }
}
