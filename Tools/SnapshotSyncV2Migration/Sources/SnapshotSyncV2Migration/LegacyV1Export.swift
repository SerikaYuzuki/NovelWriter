import SQLite3
import Foundation
import CryptoKit
import NovelCore
import NovelStorage
import NovelSync

/// 旧v1 SQLiteを読み取り、v2切替前の検証済みportable backupを作る移行専用API。
///
/// このモジュールは通常のアプリtargetから参照しない。入力DBは`SQLITE_OPEN_READONLY`
/// で開き、出力は指定されたstage rootだけへ書き込む。stage rootにあるpackageは
/// adoption markerを持たないため、途中終了してもlive libraryへ取り込まれない。
public struct LegacyV1ExportOptions: Sendable {
    public let sourceSQLiteURL: URL
    public let classificationLedgerURL: URL
    public let stageRootURL: URL

    public init(sourceSQLiteURL: URL, classificationLedgerURL: URL, stageRootURL: URL) {
        self.sourceSQLiteURL = sourceSQLiteURL
        self.classificationLedgerURL = classificationLedgerURL
        self.stageRootURL = stageRootURL
    }
}

public enum LegacyV1Disposition: String, Codable, Sendable {
    case verified
    case quarantine
    case needsReview = "needs-review"
}

public struct LegacyV1ExportEntry: Codable, Equatable, Sendable {
    public let workID: UUID
    public let disposition: LegacyV1Disposition
    public let snapshotID: String?
    public let outputRelativePath: String?
    public let outcome: String
    public let note: String?

    public init(
        workID: UUID,
        disposition: LegacyV1Disposition,
        snapshotID: String?,
        outputRelativePath: String?,
        outcome: String,
        note: String?
    ) {
        self.workID = workID
        self.disposition = disposition
        self.snapshotID = snapshotID
        self.outputRelativePath = outputRelativePath
        self.outcome = outcome
        self.note = note
    }
}

public struct LegacyV1ExportReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let sourceSQLiteSHA256: String
    public let generatedAt: String
    public let attachmentsPolicy: String
    public let objectVerificationIssues: [String]
    public let entries: [LegacyV1ExportEntry]

    public init(
        sourceSQLiteSHA256: String,
        generatedAt: String,
        attachmentsPolicy: String,
        objectVerificationIssues: [String],
        entries: [LegacyV1ExportEntry]
    ) {
        formatVersion = 1
        self.sourceSQLiteSHA256 = sourceSQLiteSHA256
        self.generatedAt = generatedAt
        self.attachmentsPolicy = attachmentsPolicy
        self.objectVerificationIssues = objectVerificationIssues
        self.entries = entries
    }
}

public enum LegacyV1ExportError: Error, Equatable, Sendable {
    case sourceNotFound(URL)
    case ledgerNotFound(URL)
    case sqliteOpenFailed(String)
    case sqliteQueryFailed(String)
    case malformedClassification(workID: String, value: String)
    case duplicateClassification(UUID)
    case missingClassification(UUID)
    case invalidManifest(workID: UUID, reason: String)
    case invalidObject(objectID: String, reason: String)
    case writeFailed(String)
}

public struct LegacyV1Exporter: Sendable {
    public init() {}

    /// 全workをWorkID順に処理し、classification ledgerの分類先へstageする。
    /// 同一入力を再実行した場合は、既存packageをlogical read-backして再利用する。
    public func export(options: LegacyV1ExportOptions) async throws -> LegacyV1ExportReport {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.sourceSQLiteURL.path) else {
            throw LegacyV1ExportError.sourceNotFound(options.sourceSQLiteURL)
        }
        guard fileManager.fileExists(atPath: options.classificationLedgerURL.path) else {
            throw LegacyV1ExportError.ledgerNotFound(options.classificationLedgerURL)
        }

        let classifications = try ClassificationLedger.load(from: options.classificationLedgerURL)
        try fileManager.createDirectory(at: options.stageRootURL, withIntermediateDirectories: true)
        for disposition in LegacyV1Disposition.allCases {
            try fileManager.createDirectory(
                at: options.stageRootURL.appendingPathComponent(disposition.directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let sourceDigest = try SHA256Hex.digest(fileAt: options.sourceSQLiteURL)
        let database = try ReadOnlyV1Database(url: options.sourceSQLiteURL)
        defer { database.close() }

        let objectIssues = try database.verifyObjects()
        let works = try database.works()
        var entries: [LegacyV1ExportEntry] = []

        for work in works.sorted(by: { $0.workID.uuidString < $1.workID.uuidString }) {
            guard let classification = classifications[work.workID] else {
                throw LegacyV1ExportError.missingClassification(work.workID)
            }

            do {
                guard let snapshot = try database.snapshot(id: work.currentSnapshotID) else {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "current snapshot is missing")
                }
                let expected = SHA256Hex.digest(snapshot.manifest)
                guard expected == snapshot.snapshotID else {
                    throw LegacyV1ExportError.invalidManifest(
                        workID: work.workID,
                        reason: "snapshot digest (expected) != (snapshot.snapshotID)"
                    )
                }
                let wireSnapshot: WorkSnapshot
                do {
                    wireSnapshot = try WorkCanonicalJSON.decodeSnapshot(snapshot.manifest)
                } catch {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: String(describing: error))
                }
                let document = try wireSnapshot.materializedDocument()
                guard document.id == work.documentID, wireSnapshot.documentID.rawValue == work.documentID else {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "document identity mismatch")
                }

                let relative = classification.directoryName + "/" + work.workID.uuidString + ".novelpkg"
                let destination = options.stageRootURL.appendingPathComponent(relative)
                try await writeIdempotently(document: document, to: destination)
                entries.append(
                    LegacyV1ExportEntry(
                        workID: work.workID,
                        disposition: classification,
                        snapshotID: snapshot.snapshotID,
                        outputRelativePath: relative,
                        outcome: "exported",
                        note: "attachments and opaque resources are not present in v1 SQLite; raw archive is authoritative"
                    )
                )
            } catch {
                entries.append(
                    LegacyV1ExportEntry(
                        workID: work.workID,
                        disposition: classification,
                        snapshotID: nil,
                        outputRelativePath: nil,
                        outcome: "blocked",
                        note: String(describing: error)
                    )
                )
            }
        }

        let report = LegacyV1ExportReport(
            sourceSQLiteSHA256: sourceDigest,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            attachmentsPolicy: "SQLite v1 contains no attachment or opaque-resource payload; no automatic reconstruction is performed. Preserve the raw read-only archive.",
            objectVerificationIssues: objectIssues,
            entries: entries
        )
        try writeReport(report, to: options.stageRootURL.appendingPathComponent("migration-ledger.json"))
        return report
    }

    private func writeIdempotently(document: NovelDocument, to destination: URL) async throws {
        let repository = NovelpkgRepository()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            do {
                let existing = try await repository.load(from: destination)
                guard existing == document else {
                    throw LegacyV1ExportError.writeFailed("existing package differs at (destination.path)")
                }
                return
            } catch let error as LegacyV1ExportError {
                throw error
            } catch {
                throw LegacyV1ExportError.writeFailed("read-back failed at (destination.path): (error)")
            }
        }
        do {
            try await repository.save(document, to: destination)
            let readBack = try await repository.load(from: destination)
            guard readBack == document else {
                throw LegacyV1ExportError.writeFailed("logical read-back mismatch at (destination.path)")
            }
        } catch let error as LegacyV1ExportError {
            throw error
        } catch {
            throw LegacyV1ExportError.writeFailed(String(describing: error))
        }
    }

    private func writeReport(_ report: LegacyV1ExportReport, to url: URL) throws {
        let data = try JSONEncoder.prettySorted.encode(report)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".migration-ledger.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw LegacyV1ExportError.writeFailed("ledger: \(error)")
        }
    }
}

private extension LegacyV1Disposition {
    static var allCases: [Self] { [.verified, .quarantine, .needsReview] }

    var directoryName: String {
        switch self {
        case .verified: "verified"
        case .quarantine: "quarantine"
        case .needsReview: "needs-review"
        }
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct ClassificationLedger {
    let values: [UUID: LegacyV1Disposition]

    static func load(from url: URL) throws -> [UUID: LegacyV1Disposition] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [UUID: LegacyV1Disposition] = [:]
        for line in text.split(whereSeparator: \ .isNewline) {
            let fields = CSV.parse(String(line))
            guard fields.count >= 2, let workID = UUID(uuidString: fields[0]) else { continue }
            if fields[0].lowercased() == "workid" { continue }
            guard let disposition = disposition(for: fields[0], value: fields[1]) else {
                throw LegacyV1ExportError.malformedClassification(workID: fields[0], value: fields[1])
            }
            guard values.updateValue(disposition, forKey: workID) == nil else {
                throw LegacyV1ExportError.duplicateClassification(workID)
            }
        }
        return values
    }

    private static func disposition(for workID: String, value: String) -> LegacyV1Disposition? {
        switch value {
        case "verified", "verified_candidate", workID:
            return .verified
        case "quarantine", "legacy_quarantine_test_batch":
            return .quarantine
        case "needs-review", "needs_review", "legacy_quarantine_ambiguous_user_touched":
            return .needsReview
        default:
            return nil
        }
    }
}

private enum CSV {
    static func parse(_ line: String) -> [String] {
        var result: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                if quoted, line.index(after: index) < line.endIndex,
                   line[line.index(after: index)] == "\"" {
                    field.append("\"")
                    index = line.index(after: index)
                } else {
                    quoted.toggle()
                }
            } else if character == "," && !quoted {
                result.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        result.append(field)
        return result
    }
}

private struct LegacyWork {
    let workID: UUID
    let documentID: UUID
    let currentSnapshotID: String
}

private struct LegacySnapshot {
    let snapshotID: String
    let manifest: Data
}

private final class ReadOnlyV1Database: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database { sqlite3_close(database) }
            throw LegacyV1ExportError.sqliteOpenFailed(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
    }

    func close() {
        if let handle { sqlite3_close(handle); self.handle = nil }
    }

    func works() throws -> [LegacyWork] {
        try rows(sql: "SELECT work_id, document_id, current_local_snapshot_id FROM works ORDER BY work_id") { statement in
            guard let work = text(statement, 0), let workID = UUID(uuidString: work),
                  let document = text(statement, 1), let documentID = UUID(uuidString: document),
                  let snapshot = text(statement, 2), !snapshot.isEmpty else { return nil }
            return LegacyWork(workID: workID, documentID: documentID, currentSnapshotID: snapshot)
        }
    }

    func snapshot(id: String) throws -> LegacySnapshot? {
        try one(sql: "SELECT snapshot_id, manifest FROM snapshots WHERE snapshot_id = ?", bind: id) { statement in
            guard let snapshotID = text(statement, 0), let manifest = data(statement, 1) else { return nil }
            return LegacySnapshot(snapshotID: snapshotID, manifest: manifest)
        }
    }

    func verifyObjects() throws -> [String] {
        try rows(sql: "SELECT object_id, byte_count, bytes FROM objects ORDER BY object_id") { statement in
            guard let objectID = text(statement, 0), let bytes = data(statement, 2) else { return "invalid object row \(sqlite3_column_int(statement, 0))" }
            let count = sqlite3_column_int64(statement, 1)
            let digest = SHA256Hex.digest(bytes)
            guard count == Int64(bytes.count), digest == objectID else {
                return "object \(objectID): byte_count/digest mismatch (actual \(digest), count \(bytes.count))"
            }
            return nil
        }
    }

    private func rows<T>(sql: String, _ decode: (OpaquePointer) throws -> T?) throws -> [T] {
        guard let handle else { throw LegacyV1ExportError.sqliteOpenFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = try decode(statement) { result.append(value) }
        }
        guard sqlite3_errcode(handle) == SQLITE_OK
            || sqlite3_errcode(handle) == SQLITE_ROW
            || sqlite3_errcode(handle) == SQLITE_DONE else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return result
    }

    private func one<T>(sql: String, bind: String, _ decode: (OpaquePointer) throws -> T?) throws -> T? {
        guard let handle else { throw LegacyV1ExportError.sqliteOpenFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bind, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decode(statement)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let value = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

private enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(fileAt url: URL) throws -> String {
        digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
