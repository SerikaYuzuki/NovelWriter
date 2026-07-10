import Foundation
import NovelCore

public extension NovelpkgRepository {
    /// `.novelpkg/snapshots/<timestamp>.novelpkg` に、現在の作品状態を退避する。
    ///
    /// App 側はスナップショットの内部構造を知らず、このメソッドの戻り値を
    /// ユーザー通知などに使うだけに留める。
    @discardableResult
    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try Self.performSaveSnapshot(doc, to: url)
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

private extension NovelpkgRepository {
    static func performSaveSnapshot(_ doc: NovelDocument, to url: URL) throws -> URL {
        let fileManager = FileManager.default
        let snapshotsURL = url.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        let timestamp = snapshotTimestamp()
        var snapshotURL = snapshotsURL.appendingPathComponent("\(timestamp).novelpkg", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: snapshotURL.path) {
            snapshotURL = snapshotsURL.appendingPathComponent("\(timestamp)-\(suffix).novelpkg", isDirectory: true)
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
                let createdAt = values?.creationDate
                    ?? values?.contentModificationDate
                    ?? Date.distantPast
                return DocumentSnapshotInfo(
                    url: snapshotURL,
                    createdAt: createdAt,
                    displayName: formatter.string(from: createdAt)
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
}
