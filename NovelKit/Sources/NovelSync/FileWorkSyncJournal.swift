import Foundation

/// 呼び出し側が注入したapp-private rootへ、作品単位journalをatomic JSON保存する。
public actor FileWorkSyncJournal: WorkSyncJournal {
    /// snapshot上限とbounded outbox/reviewを同時に無損失保持できるhard cap。
    /// review(base/local/remote + retained + staged)5 revisions、full proposed、
    /// bounded conflict summariesを同時保持するreachable worst caseのheadroom。
    public static let maximumRecordByteCount = 320 * 1024 * 1024

    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        let requestedRoot = rootURL.standardizedFileURL
        guard rootURL.isFileURL,
              requestedRoot.path.hasPrefix("/"),
              requestedRoot.path != "/" else {
            throw WorkSyncJournalError.unsafeRoot
        }
        if fileManager.fileExists(atPath: requestedRoot.path) {
            let values = try requestedRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw WorkSyncJournalError.unsafeRoot
            }
        }
        let canonicalRoot = canonicalizedWorkJournalRoot(requestedRoot, fileManager: fileManager)
        guard canonicalRoot.path.hasPrefix("/"), canonicalRoot.path != "/" else {
            throw WorkSyncJournalError.unsafeRoot
        }
        self.rootURL = canonicalRoot
        self.fileManager = fileManager
    }

    public func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        let url = try recordURL(for: workID, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(at: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue <= Self.maximumRecordByteCount else {
            throw WorkSyncJournalError.invalidFile
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumRecordByteCount else {
            throw WorkSyncJournalError.invalidFile
        }
        let record = try JSONDecoder().decode(WorkSyncJournalRecord.self, from: data)
        guard try Self.makeEncoder().encode(record) == data else {
            throw WorkSyncJournalError.invalidFile
        }
        guard record.workID == workID else { throw WorkSyncJournalError.workMismatch }
        try record.validate()
        return record
    }

    public func save(_ record: WorkSyncJournalRecord) async throws {
        try record.validate()
        let destination = try recordURL(for: record.workID, createDirectory: true)
        let directory = destination.deletingLastPathComponent()
        try rejectSymbolicLinkIfPresent(at: destination)
        let temporary = directory.appendingPathComponent(".work-sync-\(UUID().uuidString).tmp")
        let data = try Self.makeEncoder().encode(record)
        guard data.count <= Self.maximumRecordByteCount else {
            throw WorkSyncJournalError.invalidFile
        }
        do {
            try data.write(to: temporary, options: [.atomic])
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func recordURL(for workID: SyncWorkID, createDirectory: Bool) throws -> URL {
        if createDirectory {
            try createSafeDirectory(rootURL)
        } else if fileManager.fileExists(atPath: rootURL.path) {
            try rejectSymbolicLink(at: rootURL)
        }
        let directory = rootURL.appendingPathComponent(workID.rawValue.uuidString, isDirectory: true)
        if createDirectory {
            try createSafeDirectory(directory)
        } else if fileManager.fileExists(atPath: directory.path) {
            try rejectSymbolicLink(at: directory)
        }
        return directory.appendingPathComponent("work-sync.json")
    }

    private func createSafeDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try rejectSymbolicLink(at: url)
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw WorkSyncJournalError.unsafeRoot
            }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try rejectSymbolicLink(at: url)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw WorkSyncJournalError.unsafeRoot
        }
    }
}

private func canonicalizedWorkJournalRoot(_ requestedRoot: URL, fileManager: FileManager) -> URL {
    var existingAncestor = requestedRoot
    var missingComponents: [String] = []
    while !fileManager.fileExists(atPath: existingAncestor.path) {
        missingComponents.append(existingAncestor.lastPathComponent)
        let parent = existingAncestor.deletingLastPathComponent()
        guard parent.path != existingAncestor.path else { break }
        existingAncestor = parent
    }
    var result = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents.reversed() {
        result.appendPathComponent(component, isDirectory: true)
    }
    return result.standardizedFileURL
}
