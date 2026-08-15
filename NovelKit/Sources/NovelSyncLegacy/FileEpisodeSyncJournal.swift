import Foundation
import NovelSync

/// 呼び出し側が注入したapp-private rootへ、話ごとの同期journalをatomic JSONで保存する。
/// Application Supportの場所やsecurity-scoped URLをこのtarget自身は決めない。
public actor FileEpisodeSyncJournal: EpisodeSyncJournal {
    public static let maximumRecordBytes = 80 * 1024 * 1024

    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        let requestedRoot = rootURL.standardizedFileURL
        guard rootURL.isFileURL,
              requestedRoot.path.hasPrefix("/"),
              requestedRoot.path != "/" else {
            throw EpisodeSyncJournalError.unsafeRoot
        }
        if fileManager.fileExists(atPath: requestedRoot.path) {
            let values = try requestedRoot.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            )
            guard values.isSymbolicLink != true,
                  values.isDirectory == true else {
                throw EpisodeSyncJournalError.unsafeRoot
            }
        }

        // 存在する親symlinkは一度だけcanonical pathへ固定する。`/var`等のOS aliasは許し、
        // init後にaliasの向き先が変わっても別場所へjournalを書かない。
        let canonicalRoot = canonicalizedJournalRoot(
            requestedRoot,
            fileManager: fileManager
        )
        guard canonicalRoot.path.hasPrefix("/"), canonicalRoot.path != "/" else {
            throw EpisodeSyncJournalError.unsafeRoot
        }
        self.rootURL = canonicalRoot
        self.fileManager = fileManager
    }

    public func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord? {
        let url = try recordURL(for: key, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(at: url)

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue <= Self.maximumRecordBytes else {
            throw EpisodeSyncJournalError.invalidFile
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumRecordBytes else {
            throw EpisodeSyncJournalError.invalidFile
        }
        let record = try Self.makeDecoder().decode(EpisodeSyncJournalRecord.self, from: data)
        guard record.key == key else { throw EpisodeSyncJournalError.keyMismatch }
        try record.validate()
        return record
    }

    public func save(_ record: EpisodeSyncJournalRecord) async throws {
        try record.validate()
        let destination = try recordURL(for: record.key, createDirectory: true)
        let directory = destination.deletingLastPathComponent()
        try rejectSymbolicLinkIfPresent(at: destination)

        let temporary = directory.appendingPathComponent(
            ".sync-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let data = try Self.makeEncoder().encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw EpisodeSyncJournalError.invalidFile
        }

        do {
            try data.write(to: temporary, options: .atomic)
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func recordURL(for key: EpisodeSyncKey, createDirectory: Bool) throws -> URL {
        if createDirectory {
            try createSafeDirectory(rootURL)
        } else if fileManager.fileExists(atPath: rootURL.path) {
            try rejectSymbolicLink(at: rootURL)
        }

        let workDirectory = rootURL.appendingPathComponent(key.workID.rawValue.uuidString, isDirectory: true)
        if createDirectory {
            try createSafeDirectory(workDirectory)
        } else if fileManager.fileExists(atPath: workDirectory.path) {
            try rejectSymbolicLink(at: workDirectory)
        }

        return workDirectory.appendingPathComponent(
            "\(key.episodeID.rawValue.uuidString).json",
            isDirectory: false
        )
    }

    private func createSafeDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try rejectSymbolicLink(at: url)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw EpisodeSyncJournalError.unsafeRoot }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try rejectSymbolicLink(at: url)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw EpisodeSyncJournalError.unsafeRoot }
    }
}

private func canonicalizedJournalRoot(_ requestedRoot: URL, fileManager: FileManager) -> URL {
    var existingAncestor = requestedRoot
    var missingComponents: [String] = []
    while !fileManager.fileExists(atPath: existingAncestor.path) {
        missingComponents.append(existingAncestor.lastPathComponent)
        let parent = existingAncestor.deletingLastPathComponent()
        guard parent.path != existingAncestor.path else { break }
        existingAncestor = parent
    }

    var canonicalRoot = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents.reversed() {
        canonicalRoot.appendPathComponent(component, isDirectory: true)
    }
    return canonicalRoot.standardizedFileURL
}
