import Foundation
import NovelCore

public extension NovelpkgRepository {
    /// `.novelpkg/snapshots/<timestamp>.novelpkg` に、現在の作品状態を退避する。
    ///
    /// App 側はスナップショットの内部構造を知らず、このメソッドの戻り値を
    /// ユーザー通知などに使うだけに留める。
    @discardableResult
    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL {
        try await saveSnapshot(doc, to: url, kind: .manual)
    }

    /// 手動または自動のスナップショットを保存する。自動分は過去へ進むほど疎になるよう間引く(D-074)。
    @discardableResult
    func saveSnapshot(
        _ doc: NovelDocument,
        to url: URL,
        kind: DocumentSnapshotKind
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try Self.performSaveSnapshot(doc, to: url, kind: kind)
        }.value
    }

    /// 作品パッケージ内のスナップショットを新しい順で返す。
    func listSnapshots(in url: URL) async throws -> [DocumentSnapshotInfo] {
        try await Task.detached(priority: .utility) {
            try Self.performListSnapshots(in: url)
        }.value
    }

    /// スナップショットの本文・資料を現在の作品パッケージへ書き戻す。
    /// 既存の `snapshots/` は保持する。
    func restoreSnapshot(from snapshotURL: URL, into packageURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Self.performRestoreSnapshot(from: snapshotURL, into: packageURL)
        }.value
    }
}

extension NovelpkgRepository {
    func pruneAutomaticSnapshots(in url: URL, now: Date) throws {
        try Self.pruneAutomaticSnapshots(in: url, now: now, fileManager: FileManager.default)
    }
}

private extension NovelpkgRepository {
    static let automaticSnapshotFilePrefix = "auto-"

    static func performSaveSnapshot(
        _ doc: NovelDocument,
        to url: URL,
        kind: DocumentSnapshotKind
    ) throws -> URL {
        let fileManager = FileManager.default
        let snapshotsURL = url.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        let timestamp = snapshotTimestamp()
        let fileName = snapshotFileName(timestamp: timestamp, kind: kind, suffix: nil)
        var snapshotURL = snapshotsURL.appendingPathComponent(fileName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: snapshotURL.path) {
            snapshotURL = snapshotsURL.appendingPathComponent(
                snapshotFileName(timestamp: timestamp, kind: kind, suffix: suffix),
                isDirectory: true
            )
            suffix += 1
        }

        do {
            // スナップショット自体には入れ子の snapshots/ を持たせない。
            try writePackageContents(
                of: doc,
                into: snapshotURL,
                contentSourceURL: url,
                snapshotsSourceURL: nil,
                fileManager: fileManager
            )
            if kind == .automatic {
                try pruneAutomaticSnapshots(
                    in: url,
                    now: Date(),
                    fileManager: fileManager
                )
            }
            return snapshotURL
        } catch let error as NovelpkgError {
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }

    static func performListSnapshots(in url: URL) throws -> [DocumentSnapshotInfo] {
        let fileManager = FileManager.default
        let snapshotsURL = url.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: snapshotsURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return []
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: snapshotsURL,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        let formatter = snapshotDisplayNameFormatter()
        return contents
            .filter { $0.pathExtension == "novelpkg" }
            .compactMap { snapshotURL -> DocumentSnapshotInfo? in
                var isSnapshotDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: snapshotURL.path, isDirectory: &isSnapshotDirectory) else {
                    return nil
                }
                guard isSnapshotDirectory.boolValue else {
                    return nil
                }

                let values = try? snapshotURL.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]
                )
                let isAutomatic = isAutomaticSnapshotFileName(snapshotURL.lastPathComponent)
                let createdAt = snapshotDate(fromFileName: snapshotURL.lastPathComponent)
                    ?? values?.creationDate
                    ?? values?.contentModificationDate
                    ?? Date.distantPast
                let formatted = formatter.string(from: createdAt)
                return DocumentSnapshotInfo(
                    url: snapshotURL,
                    createdAt: createdAt,
                    displayName: isAutomatic ? "自動 \(formatted)" : formatted,
                    isAutomatic: isAutomatic
                )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }
    }

    static func performRestoreSnapshot(from snapshotURL: URL, into packageURL: URL) throws {
        let fileManager = FileManager.default
        let doc = try performLoad(from: snapshotURL)
        let parentDirectory = packageURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        let workingURL = parentDirectory.appendingPathComponent(
            ".\(packageURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )

        do {
            // 本文・資料・未知項目はスナップショットから、snapshots/ は現在パッケージから。
            try writePackageContents(
                of: doc,
                into: workingURL,
                contentSourceURL: snapshotURL,
                snapshotsSourceURL: packageURL,
                fileManager: fileManager
            )
        } catch let error as NovelpkgError {
            try? fileManager.removeItem(at: workingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        do {
            if fileManager.fileExists(atPath: packageURL.path) {
                _ = try fileManager.replaceItemAt(packageURL, withItemAt: workingURL)
            } else {
                try fileManager.moveItem(at: workingURL, to: packageURL)
            }
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }

    static func snapshotTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    static func snapshotDisplayNameFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }

    static func snapshotFileName(
        timestamp: String,
        kind: DocumentSnapshotKind,
        suffix: Int?
    ) -> String {
        let stamped = if let suffix {
            "\(timestamp)-\(suffix)"
        } else {
            timestamp
        }
        switch kind {
        case .manual:
            return "\(stamped).novelpkg"
        case .automatic:
            return "\(automaticSnapshotFilePrefix)\(stamped).novelpkg"
        }
    }

    static func isAutomaticSnapshotFileName(_ fileName: String) -> Bool {
        fileName.hasPrefix(automaticSnapshotFilePrefix)
    }

    static func snapshotDate(fromFileName fileName: String) -> Date? {
        var stem = (fileName as NSString).deletingPathExtension
        if stem.hasPrefix(automaticSnapshotFilePrefix) {
            stem.removeFirst(automaticSnapshotFilePrefix.count)
        }
        if let zIndex = stem.lastIndex(of: "Z"), zIndex < stem.index(before: stem.endIndex) {
            stem = String(stem[...zIndex])
        }
        guard let tIndex = stem.firstIndex(of: "T") else { return nil }
        let datePart = stem[..<tIndex]
        let timePart = stem[stem.index(after: tIndex)...]
            .replacingOccurrences(of: "-", with: ":")
        let iso = "\(datePart)T\(timePart)"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    static func pruneAutomaticSnapshots(
        in packageURL: URL,
        now: Date,
        fileManager: FileManager
    ) throws {
        let listed = try performListSnapshots(in: packageURL)
        let snapshotsRoot = packageURL
            .appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
            .standardizedFileURL.path
        let rootPrefix = snapshotsRoot.hasSuffix("/") ? snapshotsRoot : snapshotsRoot + "/"
        for url in DocumentSnapshotRetention.automaticURLsToDelete(from: listed, now: now) {
            let candidate = url.standardizedFileURL.path
            guard candidate.hasPrefix(rootPrefix),
                  isAutomaticSnapshotFileName(url.lastPathComponent) else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }
}
