import CryptoKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
@testable import SnapshotSyncV2Migration
import SQLite3
import Testing

@Test("migration module loads without adopting a live store")
func migrationModuleLoads() {
    _ = LegacyV1Exporter()
}

@Test("parses 62 CRLF classification rows without collapsing logical lines")
func parsesCRLFClassificationRows() throws {
    let root = URL(fileURLWithPath: "/Volumes/Files/GitHub/NovelWriter/.tmp-v2-export-tests", isDirectory: true)
        .appendingPathComponent("classification-crlf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = root.appendingPathComponent("classification.csv")
    let rows = (0 ..< 62).map { _ in
        classificationRow(workID: UUID(), disposition: "verified")
    }.joined()
    try rows.write(to: ledger, atomically: true, encoding: .utf8)
    #expect(try LegacyV1Exporter().classificationCountForValidation(at: ledger) == 62)
}

@Test("exports a classified v1 work through NovelStorage and is idempotent")
func exportsClassifiedWork() async throws {
    let root = URL(fileURLWithPath: "/Volumes/Files/GitHub/NovelWriter/.tmp-v2-export-tests", isDirectory: true)
        .appendingPathComponent("v2-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workID = UUID()
    let documentID = UUID()
    let archiveRoot = root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    let snapshot = try WorkSnapshot(document: NovelDocument(
        id: documentID,
        title: "証拠で分類する作品",
        chapters: [Chapter(title: "第一章", content: "本文", memo: "メモ")]
    ))
    let manifest = try WorkCanonicalJSON.encodeSnapshot(snapshot)
    let objectID = SHA256.hash(data: manifest).hex
    let v1Manifest = try makeV1Manifest(workID: workID, objectID: objectID, byteCount: manifest.count)
    let snapshotID = SHA256.hash(data: v1Manifest).hex
    let sqliteURL = archiveRoot.appendingPathComponent("library.sqlite")
    try makeLegacyDatabase(
        at: sqliteURL,
        workID: workID,
        documentID: documentID,
        snapshotID: snapshotID,
        manifest: v1Manifest,
        objectID: objectID,
        object: manifest
    )
    let archiveManifestURL = try makeArchiveManifest(root: archiveRoot, sqliteURL: sqliteURL)
    let ledgerURL = root.appendingPathComponent("classification.csv")
    try classificationRow(workID: workID, disposition: "verified_candidate", snapshotID: snapshotID).write(to: ledgerURL, atomically: true, encoding: .utf8)
    let stageURL = root.appendingPathComponent("stage", isDirectory: true)
    let options = LegacyV1ExportOptions(
        sourceSQLiteURL: sqliteURL,
        classificationLedgerURL: ledgerURL,
        stageRootURL: stageURL,
        sourceArchiveRootURL: archiveRoot,
        archiveManifestURL: archiveManifestURL,
        sourceIsVerifiedArchive: true,
        expectedWorkCount: 1
    )

    let first = try await LegacyV1Exporter().export(options: options)
    #expect(first.entries == [LegacyV1ExportEntry(
        workID: workID,
        disposition: .verified,
        snapshotID: snapshotID,
        outputRelativePath: "verified/\(workID.uuidString).novelpkg",
        outcome: "exported",
        note: "attachments and opaque resources are not present in v1 SQLite; raw archive is authoritative",
        projectionDigest: SHA256.hash(data: manifest).hex
    )])
    let packageURL = stageURL.appendingPathComponent("verified/\(workID.uuidString).novelpkg")
    let readBack = try await NovelpkgRepository().load(from: packageURL)
    #expect(try WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: readBack)) == manifest)
    #expect(first.objectVerificationIssues.isEmpty)
    #expect(FileManager.default.fileExists(atPath: stageURL.appendingPathComponent("migration-ledger.json").path))
    #expect(FileManager.default.fileExists(atPath: stageURL.appendingPathComponent("COMMITTED").path))

    let second = try await LegacyV1Exporter().export(options: options)
    #expect(second.entries == first.entries)
    #expect(FileManager.default.fileExists(atPath: packageURL.path))

    try classificationRow(workID: workID, disposition: "needs-review", snapshotID: snapshotID).write(to: ledgerURL, atomically: true, encoding: .utf8)
    do {
        _ = try await LegacyV1Exporter().export(options: options)
        Issue.record("a committed stage with different provenance must not be reused")
    } catch let error as LegacyV1ExportError {
        #expect(error == .stageNotEmpty(stageURL))
    }

    let symlinkStage = root.appendingPathComponent("stage-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlinkStage, withDestinationURL: stageURL)
    do {
        _ = try await LegacyV1Exporter().export(options: optionsWithStage(options, symlinkStage))
        Issue.record("a symlink stage root must be rejected")
    } catch let error as LegacyV1ExportError {
        #expect(error == .unsafeArchivePath(URL(fileURLWithPath: symlinkStage.path)))
    }

    let walURL = URL(fileURLWithPath: sqliteURL.path + "-wal")
    try Data("not a sidecar".utf8).write(to: walURL)
    do {
        _ = try await LegacyV1Exporter().export(options: optionsWithStage(options, root.appendingPathComponent("stage-wal")))
        Issue.record("a source WAL sidecar must be rejected")
    } catch let error as LegacyV1ExportError {
        #expect(error == .sourceSidecarPresent(walURL))
    }
    try FileManager.default.removeItem(at: walURL)

    let sourceFileDigest = try SHA256.hash(data: Data(contentsOf: sqliteURL)).hex
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archiveManifestURL.path)
    try "\(sourceFileDigest)  ../library.sqlite\n".write(to: archiveManifestURL, atomically: true, encoding: .utf8)
    do {
        _ = try await LegacyV1Exporter().export(options: optionsWithStage(options, root.appendingPathComponent("stage-traversal")))
        Issue.record("manifest traversal must be rejected")
    } catch let error as LegacyV1ExportError {
        #expect(String(describing: error).contains("sourceArchiveManifestMismatch"))
    }
    try "\(sourceFileDigest)  library.sqlite\n\(sourceFileDigest)  library.sqlite\n".write(to: archiveManifestURL, atomically: true, encoding: .utf8)
    do {
        _ = try await LegacyV1Exporter().export(options: optionsWithStage(options, root.appendingPathComponent("stage-duplicate")))
        Issue.record("duplicate manifest paths must be rejected")
    } catch let error as LegacyV1ExportError {
        #expect(String(describing: error).contains("sourceArchiveManifestMismatch"))
    }
    try "\(sourceFileDigest)  ./library.sqlite\n".write(to: archiveManifestURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: archiveManifestURL.path)
    let malformedRows = [
        "not-a-uuid,verified,snapshot,date,1,snapshot,1,evidence\n",
        classificationRow(workID: workID, disposition: "unknown"),
        "\(workID.uuidString),verified\n",
        classificationRow(workID: workID, disposition: "verified") + classificationRow(workID: workID, disposition: "verified"),
        classificationRow(workID: workID, disposition: "verified") + "\r\n",
        String(classificationRow(workID: workID, disposition: "verified").dropLast(2)) + "\r"
    ]
    for (index, row) in malformedRows.enumerated() {
        try row.write(to: ledgerURL, atomically: true, encoding: .utf8)
        do {
            _ = try await LegacyV1Exporter().export(options: optionsWithStage(options, root.appendingPathComponent("classification-invalid-\(index)")))
            Issue.record("malformed classification row must be rejected")
        } catch let error as LegacyV1ExportError {
            #expect(
                String(describing: error).contains("malformedClassification") ||
                    String(describing: error).contains("duplicateClassification")
            )
        }
    }
}

private func optionsWithStage(_ options: LegacyV1ExportOptions, _ stage: URL) -> LegacyV1ExportOptions {
    LegacyV1ExportOptions(
        sourceSQLiteURL: options.sourceSQLiteURL,
        classificationLedgerURL: options.classificationLedgerURL,
        stageRootURL: stage,
        sourceArchiveRootURL: options.sourceArchiveRootURL,
        archiveManifestURL: options.archiveManifestURL,
        sourceIsVerifiedArchive: options.sourceIsVerifiedArchive,
        expectedWorkCount: options.expectedWorkCount
    )
}

@Test("blocks a work whose canonical manifest digest does not match its snapshot ID")
func blocksInvalidManifest() async throws {
    let root = URL(fileURLWithPath: "/Volumes/Files/GitHub/NovelWriter/.tmp-v2-export-tests", isDirectory: true)
        .appendingPathComponent("v2-export-invalid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = UUID()
    let documentID = UUID()
    let archiveRoot = root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    let snapshot = try WorkSnapshot(document: NovelDocument(id: documentID, title: "壊れたdigest", chapters: []))
    let manifest = try WorkCanonicalJSON.encodeSnapshot(snapshot)
    let objectID = SHA256.hash(data: manifest).hex
    let v1Manifest = try makeV1Manifest(workID: workID, objectID: objectID, byteCount: manifest.count)
    let sqliteURL = archiveRoot.appendingPathComponent("library.sqlite")
    try makeLegacyDatabase(
        at: sqliteURL,
        workID: workID,
        documentID: documentID,
        snapshotID: String(repeating: "0", count: 64),
        manifest: v1Manifest,
        objectID: objectID,
        object: manifest
    )
    let archiveManifestURL = try makeArchiveManifest(root: archiveRoot, sqliteURL: sqliteURL)
    let ledgerURL = root.appendingPathComponent("classification.csv")
    try classificationRow(workID: workID, disposition: "needs-review", snapshotID: String(repeating: "0", count: 64)).write(to: ledgerURL, atomically: true, encoding: .utf8)
    let report = try await LegacyV1Exporter().export(options: LegacyV1ExportOptions(
        sourceSQLiteURL: sqliteURL,
        classificationLedgerURL: ledgerURL,
        stageRootURL: root.appendingPathComponent("stage", isDirectory: true),
        sourceArchiveRootURL: archiveRoot,
        archiveManifestURL: archiveManifestURL,
        sourceIsVerifiedArchive: true,
        expectedWorkCount: 1
    ))
    #expect(report.entries.first?.outcome == "blocked")
    #expect(report.entries.first?.outputRelativePath == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stage/COMMITTED").path))
}

@Test("blocks a missing or mismatched referenced document object")
func blocksReferencedObjectFailure() async throws {
    let root = URL(fileURLWithPath: "/Volumes/Files/GitHub/NovelWriter/.tmp-v2-export-tests", isDirectory: true)
        .appendingPathComponent("v2-export-object-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = UUID()
    let documentID = UUID()
    let archiveRoot = root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    let snapshot = try WorkSnapshot(document: NovelDocument(id: documentID, title: "参照object", chapters: []))
    let documentBytes = try WorkCanonicalJSON.encodeSnapshot(snapshot)
    let objectID = SHA256.hash(data: documentBytes).hex
    let v1Manifest = try makeV1Manifest(workID: workID, objectID: objectID, byteCount: documentBytes.count)
    let sqliteURL = archiveRoot.appendingPathComponent("library.sqlite")
    try makeLegacyDatabase(
        at: sqliteURL,
        workID: workID,
        documentID: documentID,
        snapshotID: SHA256.hash(data: v1Manifest).hex,
        manifest: v1Manifest,
        objectID: objectID,
        object: Data("not-the-document".utf8)
    )
    let archiveManifestURL = try makeArchiveManifest(root: archiveRoot, sqliteURL: sqliteURL)
    let ledgerURL = root.appendingPathComponent("classification.csv")
    try classificationRow(workID: workID, disposition: "verified", snapshotID: SHA256.hash(data: v1Manifest).hex).write(to: ledgerURL, atomically: true, encoding: .utf8)
    let report = try await LegacyV1Exporter().export(options: LegacyV1ExportOptions(
        sourceSQLiteURL: sqliteURL,
        classificationLedgerURL: ledgerURL,
        stageRootURL: root.appendingPathComponent("stage", isDirectory: true),
        sourceArchiveRootURL: archiveRoot,
        archiveManifestURL: archiveManifestURL,
        sourceIsVerifiedArchive: true,
        expectedWorkCount: 1
    ))
    #expect(report.entries.first?.outcome == "blocked")
    #expect(report.entries.first?.note?.contains("referenced object is invalid") == true)
}

@Test("blocks a missing referenced object")
func blocksMissingReferencedObject() async throws {
    let root = URL(fileURLWithPath: "/Volumes/Files/GitHub/NovelWriter/.tmp-v2-export-tests", isDirectory: true)
        .appendingPathComponent("v2-export-object-missing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = UUID()
    let documentID = UUID()
    let archiveRoot = root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    let documentBytes = try WorkCanonicalJSON.encodeSnapshot(
        WorkSnapshot(document: NovelDocument(id: documentID, title: "欠落object", chapters: []))
    )
    let objectID = SHA256.hash(data: documentBytes).hex
    let v1Manifest = try makeV1Manifest(workID: workID, objectID: objectID, byteCount: documentBytes.count)
    let sqliteURL = archiveRoot.appendingPathComponent("library.sqlite")
    try makeLegacyDatabase(
        at: sqliteURL,
        workID: workID,
        documentID: documentID,
        snapshotID: SHA256.hash(data: v1Manifest).hex,
        manifest: v1Manifest,
        objectID: nil,
        object: nil
    )
    let archiveManifestURL = try makeArchiveManifest(root: archiveRoot, sqliteURL: sqliteURL)
    let ledgerURL = root.appendingPathComponent("classification.csv")
    try classificationRow(workID: workID, disposition: "quarantine", snapshotID: SHA256.hash(data: v1Manifest).hex).write(to: ledgerURL, atomically: true, encoding: .utf8)
    let report = try await LegacyV1Exporter().export(options: LegacyV1ExportOptions(
        sourceSQLiteURL: sqliteURL,
        classificationLedgerURL: ledgerURL,
        stageRootURL: root.appendingPathComponent("stage", isDirectory: true),
        sourceArchiveRootURL: archiveRoot,
        archiveManifestURL: archiveManifestURL,
        sourceIsVerifiedArchive: true,
        expectedWorkCount: 1
    ))
    #expect(report.entries.first?.outcome == "blocked")
    #expect(report.entries.first?.note?.contains("referenced object is missing") == true)
}

private func makeV1Manifest(workID: UUID, objectID: String, byteCount: Int) throws -> Data {
    let value: [String: Any] = [
        "entries": [[
            "byteCount": byteCount,
            "contentType": "application/vnd.fuminiwa.entity+json;version=1",
            "entityKey": "work/document",
            "objectId": objectID
        ]],
        "parentSnapshotIds": [],
        "schemaVersion": 1,
        "workId": workID.uuidString.uppercased()
    ]
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func classificationRow(workID: UUID, disposition: String, snapshotID: String = String(repeating: "0", count: 64)) -> String {
    "\(workID.uuidString),\(disposition),\(snapshotID),2026-08-17T00:00:00Z,4,\(snapshotID),4,evidence\r\n"
}

private func makeArchiveManifest(root: URL, sqliteURL: URL) throws -> URL {
    let digest = try SHA256.hash(data: Data(contentsOf: sqliteURL)).hex
    let manifestURL = root.appendingPathComponent("sha256-manifest.txt")
    try "\(digest)  ./\(sqliteURL.lastPathComponent)\n".write(to: manifestURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sqliteURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: manifestURL.path)
    return manifestURL
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
    CREATE TABLE works(work_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, document_created_at TEXT NOT NULL, current_local_snapshot_id TEXT, local_generation INTEGER NOT NULL DEFAULT 0, acknowledged_head_snapshot_id TEXT, acknowledged_head_generation INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE snapshots(snapshot_id TEXT PRIMARY KEY, work_id TEXT NOT NULL, parent_snapshot_ids TEXT NOT NULL, manifest BLOB NOT NULL, reason TEXT NOT NULL, local_generation INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    CREATE TABLE objects(object_id TEXT PRIMARY KEY, byte_count INTEGER NOT NULL, bytes BLOB NOT NULL);
    """)
    try exec(database, "INSERT INTO works VALUES ('\(workID.uuidString.lowercased())','\(documentID.uuidString.lowercased())','2026-08-17T00:00:00Z','\(snapshotID)',4,'\(snapshotID)',4)")
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
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
