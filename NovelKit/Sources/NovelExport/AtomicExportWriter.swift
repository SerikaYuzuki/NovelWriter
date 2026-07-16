import Foundation

enum AtomicExportWriter {
    typealias Commit = (_ temporaryURL: URL, _ destinationURL: URL, _ fileManager: FileManager) throws -> Void

    static func write(_ data: Data, to destinationURL: URL) throws {
        try write(
            data,
            to: destinationURL,
            fileManager: .default,
            commit: commitTemporaryFile
        )
    }

    /// テストでは `commit` に失敗を注入し、既存出力と一時ファイルの保全を確認する。
    static func write(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager,
        commit: Commit
    ) throws {
        guard destinationURL.isFileURL else {
            throw ExportError.invalidDestination(destinationURL)
        }

        let parentDirectory = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.destinationPreparationFailed(
                destination: destinationURL,
                reason: String(describing: error)
            )
        }

        // move / replace が同一ボリューム上のrenameになるよう、必ず保存先と同じ親に置く。
        let temporaryURL = parentDirectory.appendingPathComponent(
            ".novel-export-\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ExportError.temporaryWriteFailed(
                destination: destinationURL,
                reason: String(describing: error)
            )
        }

        do {
            try commit(temporaryURL, destinationURL, fileManager)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ExportError.destinationReplacementFailed(
                destination: destinationURL,
                reason: String(describing: error)
            )
        }
    }

    private static func commitTemporaryFile(
        _ temporaryURL: URL,
        _ destinationURL: URL,
        _ fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}
