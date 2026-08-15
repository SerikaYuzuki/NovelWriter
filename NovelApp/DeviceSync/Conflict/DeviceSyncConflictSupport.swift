import Darwin
import Foundation
import NovelCore
import NovelSync

enum DeviceSyncMergeRecoveryPurpose: String, Codable, Hashable, Sendable {
    case reviewDraft
    case acceptedResolution
}

struct DeviceSyncMergeRecoveryRecord: Codable, Hashable, Sendable {
    let localWorkingCopyID: LocalWorkingCopyID
    let key: EpisodeSyncKey
    let localParentRevisionID: SyncRevisionID
    let remoteParentRevisionID: SyncRevisionID
    let content: String
    let contentDigest: SyncContentDigest
    /// `nil` is a pre-D-060 record and is treated as review-only (fail closed).
    let purpose: DeviceSyncMergeRecoveryPurpose?

    init(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey,
        conflict: EpisodeConflict,
        content: String,
        purpose: DeviceSyncMergeRecoveryPurpose = .reviewDraft
    ) {
        self.localWorkingCopyID = localWorkingCopyID
        self.key = key
        localParentRevisionID = conflict.local.revisionID
        remoteParentRevisionID = conflict.remote.revisionID
        self.content = content
        contentDigest = SyncContentDigest(content: content)
        self.purpose = purpose
    }

    var parentRevisionIDs: Set<SyncRevisionID> {
        [localParentRevisionID, remoteParentRevisionID]
    }
}

protocol DeviceSyncMergeRecoveryStoring: Sendable {
    func load(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) async throws -> DeviceSyncMergeRecoveryRecord?
    func save(_ record: DeviceSyncMergeRecoveryRecord) async throws
    func remove(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) async throws
}

actor InMemoryDeviceSyncMergeRecoveryStore: DeviceSyncMergeRecoveryStoring {
    private var records: [String: DeviceSyncMergeRecoveryRecord] = [:]

    func load(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) -> DeviceSyncMergeRecoveryRecord? {
        records[Self.storageKey(localWorkingCopyID: localWorkingCopyID, key: key)]
    }

    func save(_ record: DeviceSyncMergeRecoveryRecord) {
        records[Self.storageKey(localWorkingCopyID: record.localWorkingCopyID, key: record.key)] = record
    }

    func remove(localWorkingCopyID: LocalWorkingCopyID, key: EpisodeSyncKey) {
        records.removeValue(forKey: Self.storageKey(localWorkingCopyID: localWorkingCopyID, key: key))
    }

    private static func storageKey(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) -> String {
        let work = key.workID.rawValue.uuidString
        let episode = key.episodeID.rawValue.uuidString
        return "\(localWorkingCopyID.rawValue.uuidString):\(work):\(episode)"
    }
}

actor FileDeviceSyncMergeRecoveryStore: DeviceSyncMergeRecoveryStoring {
    /// NovelSync journalと同じhard cap。記録は1 MiB以下のchosen contentを1つだけ
    /// 保持するが、JSON control escapeの最悪ケースもこの範囲で読み戻せる。
    static let maximumRecordBytes = 64 * 1024 * 1024

    private let rootURL: URL
    private let rootIdentity: RootIdentity
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL, trustedAncestorURL: URL) throws {
        let fileManager = FileManager()
        let prepared = try Self.prepareAnchoredRoot(
            rootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.rootURL = prepared.url
        rootIdentity = prepared.identity
        self.fileManager = fileManager
        encoder.outputFormatting = [.sortedKeys]
    }

    func load(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) throws -> DeviceSyncMergeRecoveryRecord? {
        try validateFixedRoot()
        let url = recordURL(localWorkingCopyID: localWorkingCopyID, key: key)
        guard let status = try pathStatus(at: url) else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
        let data = try readBoundedRegularFile(at: url)
        let record = try decoder.decode(DeviceSyncMergeRecoveryRecord.self, from: data)
        guard record.localWorkingCopyID == localWorkingCopyID, record.key == key else {
            throw DeviceSyncMergeRecoveryStoreError.identityMismatch
        }
        try validate(record)
        return record
    }

    func save(_ record: DeviceSyncMergeRecoveryRecord) throws {
        try validateFixedRoot()
        try validate(record)
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw DeviceSyncMergeRecoveryStoreError.recordTooLarge
        }
        let destination = recordURL(localWorkingCopyID: record.localWorkingCopyID, key: record.key)
        if let status = try pathStatus(at: destination), status.st_mode & S_IFMT != S_IFREG {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
        try data.write(to: destination, options: .atomic)
        try validateFixedRoot()
        try validateRegularNonSymlinkPath(destination)
    }

    func remove(localWorkingCopyID: LocalWorkingCopyID, key: EpisodeSyncKey) throws {
        try validateFixedRoot()
        let url = recordURL(localWorkingCopyID: localWorkingCopyID, key: key)
        guard let status = try pathStatus(at: url) else { return }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
        try fileManager.removeItem(at: url)
    }

    private func recordURL(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) -> URL {
        let identity = [
            "fuminiwa-device-sync-merge-recovery-v1",
            localWorkingCopyID.rawValue.uuidString,
            key.workID.rawValue.uuidString,
            key.episodeID.rawValue.uuidString
        ].joined(separator: "\n")
        let filename = SyncContentDigest(content: identity).rawValue + ".json"
        return rootURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func validateFixedRoot() throws {
        var info = stat()
        guard lstat(rootURL.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              RootIdentity(info) == rootIdentity else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
    }

    private func pathStatus(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return info
        }
        guard errno == ENOENT else {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
        return nil
    }

    private func readBoundedRegularFile(at url: URL) throws -> Data {
        try validateRegularNonSymlinkPath(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DeviceSyncMergeRecoveryStoreError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Self.maximumRecordBytes else {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
        let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecordBytes else {
            throw DeviceSyncMergeRecoveryStoreError.recordTooLarge
        }
        return data
    }

    private func validateRegularNonSymlinkPath(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
    }

    private func validate(_ record: DeviceSyncMergeRecoveryRecord) throws {
        guard record.content.utf8.count <= EpisodeRevision.maximumContentUTF8Bytes,
              record.localParentRevisionID != record.remoteParentRevisionID,
              record.contentDigest == SyncContentDigest(content: record.content) else {
            throw DeviceSyncMergeRecoveryStoreError.invalidFile
        }
    }

    static func prepareAnchoredRoot(
        _ requestedURL: URL,
        trustedAncestorURL: URL,
        fileManager: FileManager
    ) throws -> (url: URL, identity: RootIdentity) {
        let requested = requestedURL.standardizedFileURL
        let trusted = trustedAncestorURL.standardizedFileURL
        guard requestedURL.isFileURL,
              trustedAncestorURL.isFileURL,
              requested.path.hasPrefix(trusted.path + "/"),
              let resolvedPointer = realpath(trusted.path, nil) else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        defer { free(resolvedPointer) }
        var canonical = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
            .standardizedFileURL
        let relativePath = String(requested.path.dropFirst(trusted.path.count))
        for component in relativePath.split(separator: "/").map(String.init) {
            canonical.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(canonical.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
                }
            } else {
                guard errno == ENOENT else {
                    throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
                }
                do {
                    try fileManager.createDirectory(at: canonical, withIntermediateDirectories: false)
                } catch {
                    throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
                }
            }
        }
        var rootInfo = stat()
        guard lstat(canonical.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        return (canonical, RootIdentity(rootInfo))
    }

    struct RootIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }
}

enum DeviceSyncMergeRecoveryStoreError: Error, Equatable, Sendable {
    case unsafeRoot
    case invalidFile
    case identityMismatch
    case recordTooLarge
}

struct DeviceSyncConflictDraft: Equatable {
    enum Kind: Equatable {
        case automaticIntegration
        case manualIntegrationRequired
        case recoveredIntegration
    }

    let content: String
    let kind: Kind

    init(conflict: EpisodeConflict, recoveredContent: String? = nil) {
        if let recoveredContent {
            content = recoveredContent
            kind = .recoveredIntegration
            return
        }
        guard let base = conflict.base else {
            content = conflict.local.content
            kind = .manualIntegrationRequired
            return
        }

        switch PortableThreeWayTextMerger.analyze(
            base: base.content,
            local: conflict.local.content,
            remote: conflict.remote.content
        ) {
        case let .merged(merged):
            content = merged
            kind = .automaticIntegration
        case let .conflict(analysis):
            content = analysis.proposedContent
            kind = .manualIntegrationRequired
        }
    }

    var title: String {
        switch kind {
        case .automaticIntegration:
            "自動統合の下書き"
        case .manualIntegrationRequired:
            "手動で統合"
        case .recoveredIntegration:
            "前回の統合案を再開"
        }
    }

    var message: String {
        switch kind {
        case .automaticIntegration:
            "離れた箇所の変更を組み合わせました。内容を確認してから保存してください。"
        case .manualIntegrationRequired:
            "変更箇所が重なっているため、この端末の本文を下書きにしています。もう一方の端末と見比べて統合してください。"
        case .recoveredIntegration:
            "以前に選んだ統合本文を復元しました。現在の2つの変更と見比べ、内容を再確認してから保存してください。"
        }
    }
}
