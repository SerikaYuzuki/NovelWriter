import Darwin
import Foundation
import NovelCore
import NovelSync

/// App層がDevice Syncを有効化するための任意注入値。
///
/// `nil`なら従来のapp-private package執筆だけで動く。
/// CloudKitの具象型やcontainer設定はAppStateへ露出さない。
struct DeviceSyncRuntime {
    let replicaID: SyncReplicaID
    let transport: any EpisodeSyncTransport
    let binding: @Sendable (
        DocumentSessionToken,
        SyncWorkStructureDigest
    ) async throws -> DeviceSyncBindingResolution?
    let remoteChangeSignals: AsyncStream<Void>?
    let mergeRecoveryStore: any DeviceSyncMergeRecoveryStoring
    let setup: DeviceSyncSetupRuntime?
    let now: @Sendable () -> Date
    let leaseDuration: TimeInterval

    init(
        replicaID: SyncReplicaID,
        transport: any EpisodeSyncTransport,
        binding: @escaping @Sendable (
            DocumentSessionToken,
            SyncWorkStructureDigest
        ) async throws -> DeviceSyncBindingResolution?,
        remoteChangeSignals: AsyncStream<Void>? = nil,
        mergeRecoveryStore: any DeviceSyncMergeRecoveryStoring = InMemoryDeviceSyncMergeRecoveryStore(),
        setup: DeviceSyncSetupRuntime? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        leaseDuration: TimeInterval = 120
    ) {
        self.replicaID = replicaID
        self.transport = transport
        self.binding = binding
        self.remoteChangeSignals = remoteChangeSignals
        self.mergeRecoveryStore = mergeRecoveryStore
        self.setup = setup
        self.now = now
        self.leaseDuration = leaseDuration
    }

    func leaseExpiration() -> Date {
        now().addingTimeInterval(leaseDuration)
    }
}

struct DeviceSyncSetupRuntime: Sendable {
    /// `nil`なら現在URLはapp-private。URLを返した場合は、同期操作前に
    /// package全体をそこへcopy-inし、新しいdocument sessionへ切り替える。
    let privateWorkingCopyDestination: @Sendable (DocumentSessionToken) throws -> URL?
    /// copy完了後、URL/recent/sessionを採用する前にfixed rootと
    /// package rootのidentityを検査する。
    let validatePrivateWorkingCopy: @Sendable (URL) throws -> Void
    let candidates: @Sendable (
        DocumentSessionToken,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor]
    let startNew: @Sendable (
        DocumentSessionToken,
        SyncWorkDescriptor,
        [EpisodeID]
    ) async throws -> Void
    let bindExisting: @Sendable (
        DocumentSessionToken,
        UUID,
        SyncWorkStructureDigest,
        SyncWorkID,
        [EpisodeID]
    ) async throws -> Void
}

enum DeviceSyncSetupState: Equatable {
    case idle
    case loading
    case candidates([SyncWorkDescriptor])
    case configured
    case unavailable(message: String)
}

struct PendingDeviceSyncNewWork {
    let session: DocumentSessionToken
    let structureDigest: SyncWorkStructureDigest
    let descriptor: SyncWorkDescriptor
}

enum DeviceSyncTransferState: Hashable {
    case notApplicable
    case localPending
    case uploading
    case upToDate
}

struct DeviceSyncBindingResolution: Sendable {
    let binding: SyncWorkingCopyBinding
    let descriptor: SyncWorkDescriptor
    let journal: any EpisodeSyncJournal
    let allowedEpisodeIDs: Set<EpisodeID>
}

enum DeviceSyncUIState: Hashable {
    case unconfigured
    case episodeNotIncluded
    case writer
    case readOnly
    case forcing
    case offlineLocal
    case conflict(EpisodeConflict)
    case syncing
    case blocked

    var allowsEditing: Bool {
        switch self {
        case .unconfigured, .episodeNotIncluded, .writer, .offlineLocal:
            true
        case .readOnly, .forcing, .conflict, .syncing, .blocked:
            false
        }
    }

    var isConfigured: Bool {
        self != .unconfigured
    }
}

struct DeviceSyncEpisodeIdentity: Hashable {
    let documentSession: DocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
    let structureDigest: SyncWorkStructureDigest
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

/// bindingの非同期解決を、解決開始時の作品・話・Editor世代へ固定する。
/// `NovelDocument.id`はremote identityに使わない。
struct DeviceSyncLookupIdentity: Hashable {
    let documentSession: DocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
    let structureDigest: SyncWorkStructureDigest
}

struct DeviceSyncClient {
    let coordinator: EpisodeSyncCoordinator
    let sessionID: SyncEditSessionID
}

struct DeviceSyncClientKey: Hashable {
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct PendingDeviceSyncConflictResolution {
    let key: EpisodeSyncKey
    let conflict: EpisodeConflict
    let content: String
}

struct DeviceSyncMergeRecoveryRecord: Codable, Hashable, Sendable {
    let localWorkingCopyID: LocalWorkingCopyID
    let key: EpisodeSyncKey
    let localParentRevisionID: SyncRevisionID
    let remoteParentRevisionID: SyncRevisionID
    let content: String
    let contentDigest: SyncContentDigest

    init(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey,
        conflict: EpisodeConflict,
        content: String
    ) {
        self.localWorkingCopyID = localWorkingCopyID
        self.key = key
        localParentRevisionID = conflict.local.revisionID
        remoteParentRevisionID = conflict.remote.revisionID
        self.content = content
        contentDigest = SyncContentDigest(content: content)
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
        "\(localWorkingCopyID.rawValue.uuidString):\(key.workID.rawValue.uuidString):\(key.episodeID.rawValue.uuidString)"
    }
}

actor FileDeviceSyncMergeRecoveryStore: DeviceSyncMergeRecoveryStoring {
    /// NovelSync journalと同じhard cap。記録は1 MiB以下のchosen contentを1つだけ
    /// 保持するが、JSON control escapeの最悪ケースもこの範囲で読み戻せる。
    static let maximumRecordBytes = 64 * 1_024 * 1_024

    private let rootURL: URL
    private let rootIdentity: RootIdentity
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL) throws {
        let fileManager = FileManager()
        let prepared = try Self.prepareCanonicalRoot(rootURL, fileManager: fileManager)
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

    private static func prepareCanonicalRoot(
        _ requestedURL: URL,
        fileManager: FileManager
    ) throws -> (url: URL, identity: RootIdentity) {
        let requested = requestedURL.standardizedFileURL
        guard requestedURL.isFileURL,
              requested.path.hasPrefix("/"),
              requested.path != "/",
              requested.pathComponents.count >= 4 else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }

        var requestedInfo = stat()
        if lstat(requested.path, &requestedInfo) == 0,
           requestedInfo.st_mode & S_IFMT == S_IFLNK
        {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }

        var existingAncestor = requested
        var missingComponents: [String] = []
        while true {
            var info = stat()
            if lstat(existingAncestor.path, &info) == 0 {
                break
            }
            guard errno == ENOENT, existingAncestor.path != "/" else {
                throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = existingAncestor.deletingLastPathComponent()
        }

        guard let resolvedPointer = realpath(existingAncestor.path, nil) else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        defer { free(resolvedPointer) }
        var canonical = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
            .standardizedFileURL
        for component in missingComponents {
            canonical.appendPathComponent(component, isDirectory: true)
        }
        guard canonical.path != "/", canonical.pathComponents.count >= 4 else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        do {
            try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        } catch {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        var rootInfo = stat()
        guard lstat(canonical.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw DeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        return (canonical, RootIdentity(rootInfo))
    }

    private struct RootIdentity: Equatable {
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

struct DeviceSyncForceContinuationConfirmation {
    var isPresented = false

    mutating func request() {
        isPresented = true
    }

    mutating func cancel() {
        isPresented = false
    }

    mutating func confirm(perform action: () -> Void) {
        guard isPresented else { return }
        isPresented = false
        action()
    }
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

        switch PortableThreeWayTextMerger.merge(
            base: base.content,
            local: conflict.local.content,
            remote: conflict.remote.content
        ) {
        case let .merged(merged):
            content = merged
            kind = .automaticIntegration
        case .conflict:
            content = conflict.local.content
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
            "変更箇所が重なっているため、この端末の本文を下書きにしています。同期先と見比べて統合してください。"
        case .recoveredIntegration:
            "以前に選んだ統合本文を復元しました。現在の2つの変更と見比べ、内容を再確認してから保存してください。"
        }
    }
}
