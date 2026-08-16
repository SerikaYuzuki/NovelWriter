import CryptoKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
import SQLite3
import SnapshotSyncV2Migration
import Testing

@Test("migration module loads without adopting a live store")
func migrationModuleLoads() {
    _ = LegacyV1Exporter()
}

@Test("exports a classified v1 work through NovelStorage and is idempotent")
func exportsClassifiedWork() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("v2-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workID = UUID()
    let documentID = UUID()
    let snapshot = try WorkSnapshot(document: NovelDocument(
        id: documentID,
        title: "証拠で分類する作品",
        chapters: [Chapter(title: "第一章", content: "本文", memo: "メモ")]
    ))
    let manifest = try WorkCanonicalJSON.encodeSnapshot(snapshot)
    let snapshotID = SHA256.hash(data: manifest).hex
    let object = Data("opaque-test-object".utf8)
    let objectID = SHA256.hash(data: object).hex
    let sqliteURL = root.appendingPathComponent("legacy.sqlite")
    try makeLegacyDatabase(
        at: sqliteURL,
        workID: workID,
        documentID: documentID,
        snapshotID: snapshotID,
        manifest: manifest,
        objectID: objectID,
        object: object
    )
    let ledgerURL = root.appendingPathComponent("classification.csv")
    try "\(workID.uuidString),verified_candidate\n".write(to: ledgerURL, atomically: true, encoding: .utf8)
    let stageURL = root.appendingPathComponent("stage", isDirectory: true)
    let options = LegacyV1ExportOptions(
        sourceSQLiteURL: sqliteURL,
        classificationLedgerURL: ledgerURL,
        stageRootURL: stageURL
    )

    let first = try await LegacyV1Exporter().export(options: options)
    #expect(first.entries == [LegacyV1ExportEntry(
        workID: workID,
        disposition: .verified,
        snapshotID: snapshotID,
        outputRelativePath: "verified/\(workID.uuidString).novelpkg",
        outcome: "exported",
        note: "attachments and opaque resources are not present in v1 SQLite; raw archive is authoritative"
    )])
    let packageURL = stageURL.appendingPathComponent("verified/\(workID.uuidString).novelpkg")
    let readBack = try await NovelpkgRepository().load(from: packageURL)
    #expect(try WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: readBack)) == manifest)
    #expect(first.objectVerificationIssues.isEmpty)
    #expect(FileManager.default.fileExists(atPath: stageURL.appendingPathComponent("migration-ledger.json").path))

    let second = try await LegacyV1Exporter().export(options: options)
    #expect(second.entries == first.entries)
    #expect(FileManager.default.fileExists(atPath: packageURL.path))
}

@Test("blocks a work whose canonical manifest digest does not match its snapshot ID")
func blocksInvalidManifest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("v2-export-invalid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = UUID()
    let documentID = UUID()
    let snapshot = try WorkSnapshot(document: NovelDocument(id: documentID, title: "壊れたdigest", chapters: []))
    let manifest = try WorkCanonicalJSON.encodeSnapshot(snapshot)
    let sqliteURL = root.appendingPathComponent("legacy.sqlite")
    try makeLegacyDatabase(
        at: sqliteURL,
        workID: workID,
        documentID: documentID,
        snapshotID: String(repeating: "0", count: 64),
        manifest: manifest,
        objectID: nil,
        object: nil
    )
    let ledgerURL = root.appendingPathComponent("classification.csv")
    try "\(workID.uuidString),needs-review\n".write(to: ledgerURL, atomically: true, encoding: .utf8)
    let report = try await LegacyV1Exporter().export(options: LegacyV1ExportOptions(
        sourceSQLiteURL: sqliteURL,
        classificationLedgerURL: ledgerURL,
        stageRootURL: root.appendingPathComponent("stage", isDirectory: true)
    ))
    #expect(report.entries.first?.outcome == "blocked")
    #expect(report.entries.first?.outputRelativePath == nil)
}

private func makeLegacyDatabase(
    at url: URL,
    workID: UUID,
    documentID: UUID,
    snapshotID: String,
    manifest: Data,
    objectID: String?,
    object: Data?
) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    guard let database else { throw FixtureError.open }
    defer { sqlite3_close(database) }
    try exec(database, """
    CREATE TABLE works(work_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, document_created_at TEXT NOT NULL, current_local_snapshot_id TEXT, local_generation INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE snapshots(snapshot_id TEXT PRIMARY KEY, work_id TEXT NOT NULL, parent_snapshot_ids TEXT NOT NULL, manifest BLOB NOT NULL, reason TEXT NOT NULL, local_generation INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    CREATE TABLE objects(object_id TEXT PRIMARY KEY, byte_count INTEGER NOT NULL, bytes BLOB NOT NULL);
    """)
    try exec(database, "INSERT INTO works VALUES ('\(workID.uuidString.lowercased())','\(documentID.uuidString.lowercased())','2026-08-17T00:00:00Z','\(snapshotID)',1)")
    try insertSnapshot(database, snapshotID: snapshotID, workID: workID, manifest: manifest)
    if let objectID, let object {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO objects VALUES (?,?,?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureError.query }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, objectID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(object.count))
        _ = object.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(object.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.query }
    }
}

private func insertSnapshot(_ database: OpaquePointer, snapshotID: String, workID: UUID, manifest: Data) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO snapshots VALUES (?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw FixtureError.query }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, snapshotID, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, workID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 3, "[]", -1, SQLITE_TRANSIENT)
    _ = manifest.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(manifest.count), SQLITE_TRANSIENT)
    }
    sqlite3_bind_text(statement, 5, "autosave", -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 6, 1)
    sqlite3_bind_int(statement, 7, 0)
    sqlite3_bind_text(statement, 8, "2026-08-17T00:00:00Z", -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.query }
}

private func exec(_ database: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "sqlite error"
        sqlite3_free(error)
        throw FixtureError.message(message)
    }
}

private enum FixtureError: Error {
    case open
    case query
    case message(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
