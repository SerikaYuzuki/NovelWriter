import Foundation
import NovelCore

extension NovelpkgRepository: AttachmentManaging {
    public func listAttachments(in packageURL: URL) async throws -> [Attachment] {
        try await Task.detached(priority: .utility) {
            try Self.performListAttachments(in: packageURL)
        }.value
    }

    @discardableResult
    public func addAttachment(from sourceURL: URL, to packageURL: URL) async throws -> Attachment {
        try await Task.detached(priority: .utility) {
            try Self.performAddAttachment(from: sourceURL, to: packageURL)
        }.value
    }

    public func deleteAttachment(named fileName: String, from packageURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Self.performDeleteAttachment(named: fileName, from: packageURL)
        }.value
    }

    public func attachmentURL(named fileName: String, in packageURL: URL) -> URL {
        Self.attachmentsURL(in: packageURL).appendingPathComponent(Self.safeAttachmentFileName(fileName))
    }
}

private extension NovelpkgRepository {
    static func performListAttachments(in packageURL: URL) throws -> [Attachment] {
        let fileManager = FileManager.default
        try ensurePackageExists(at: packageURL, fileManager: fileManager)

        let attachmentsURL = attachmentsURL(in: packageURL)
        guard fileManager.fileExists(atPath: attachmentsURL.path) else { return [] }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: attachmentsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try fileURLs.compactMap { fileURL in
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            return Attachment(fileName: fileURL.lastPathComponent, byteCount: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    static func performAddAttachment(from sourceURL: URL, to packageURL: URL) throws -> Attachment {
        let fileManager = FileManager.default
        try ensurePackageExists(at: packageURL, fileManager: fileManager)

        let attachmentsURL = attachmentsURL(in: packageURL)
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        let destinationURL = uniqueAttachmentURL(
            for: safeAttachmentFileName(sourceURL.lastPathComponent),
            in: attachmentsURL,
            fileManager: fileManager
        )

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
            return Attachment(fileName: destinationURL.lastPathComponent, byteCount: Int64(values.fileSize ?? 0))
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }

    static func performDeleteAttachment(named fileName: String, from packageURL: URL) throws {
        let fileManager = FileManager.default
        try ensurePackageExists(at: packageURL, fileManager: fileManager)

        let targetURL = attachmentsURL(in: packageURL).appendingPathComponent(safeAttachmentFileName(fileName))
        guard fileManager.fileExists(atPath: targetURL.path) else { return }

        do {
            try fileManager.removeItem(at: targetURL)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }

    static func attachmentsURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("attachments", isDirectory: true)
    }

    static func ensurePackageExists(at packageURL: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NovelpkgError.packageNotFound(packageURL)
        }
    }

    static func safeAttachmentFileName(_ fileName: String) -> String {
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        return safeName.isEmpty ? "資料" : safeName
    }

    static func uniqueAttachmentURL(for fileName: String, in attachmentsURL: URL, fileManager: FileManager) -> URL {
        let originalURL = URL(fileURLWithPath: fileName)
        let pathExtension = originalURL.pathExtension
        let stem = originalURL.deletingPathExtension().lastPathComponent
        var candidateName = fileName
        var suffix = 2

        while fileManager.fileExists(atPath: attachmentsURL.appendingPathComponent(candidateName).path) {
            candidateName = if pathExtension.isEmpty {
                "\(stem)-\(suffix)"
            } else {
                "\(stem)-\(suffix).\(pathExtension)"
            }
            suffix += 1
        }

        return attachmentsURL.appendingPathComponent(candidateName)
    }
}
