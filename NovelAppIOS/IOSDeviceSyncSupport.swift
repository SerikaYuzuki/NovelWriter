import Darwin
import Foundation
import NovelCore
import NovelSync

struct IOSDeviceSyncRuntime {
    let replicaID: SyncReplicaID
    let transport: any EpisodeSyncTransport
    let binding: @Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> IOSDeviceSyncBindingResolution?
    let remoteChangeSignals: AsyncStream<Void>?
    let mergeRecoveryStore: any IOSDeviceSyncMergeRecoveryStoring
    let setup: IOSDeviceSyncSetupRuntime?
    let now: @Sendable () -> Date
    let leaseDuration: TimeInterval

    init(
        replicaID: SyncReplicaID,
        transport: any EpisodeSyncTransport,
        binding: @escaping @Sendable (
            IOSPrivateDocumentID,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> IOSDeviceSyncBindingResolution?,
        remoteChangeSignals: AsyncStream<Void>? = nil,
        mergeRecoveryStore: any IOSDeviceSyncMergeRecoveryStoring = IOSInMemoryDeviceSyncMergeRecoveryStore(),
        setup: IOSDeviceSyncSetupRuntime? = nil,
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

struct IOSDeviceSyncSetupRuntime: Sendable {
    let candidates: @Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor]
    let startNew: @Sendable (
        IOSPrivateDocumentID,
        SyncWorkDescriptor,
        [EpisodeID]
    ) async throws -> Void
    let bindExisting: @Sendable (
        IOSPrivateDocumentID,
        UUID,
        SyncWorkStructureDigest,
        SyncWorkID,
        [EpisodeID]
    ) async throws -> Void
}

enum IOSDeviceSyncSetupState: Equatable {
    case idle
    case loading
    case candidates([SyncWorkDescriptor])
    case configured
    case unavailable(message: String)
}

struct IOSPendingDeviceSyncNewWork {
    let session: IOSDocumentSessionToken
    let structureDigest: SyncWorkStructureDigest
    let descriptor: SyncWorkDescriptor
}

enum IOSDeviceSyncTransferState: Hashable {
    case notApplicable
    case localPending
    case uploading
    case upToDate
}

struct IOSDeviceSyncBindingResolution: Sendable {
    let binding: SyncWorkingCopyBinding
    let descriptor: SyncWorkDescriptor
    let journal: any EpisodeSyncJournal
    let allowedEpisodeIDs: Set<EpisodeID>
}

enum IOSDeviceSyncUIState: Hashable {
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

struct IOSDeviceSyncEpisodeIdentity: Hashable {
    let editingToken: IOSEpisodeEditingToken
    let structureDigest: SyncWorkStructureDigest
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct IOSDeviceSyncLookupIdentity: Hashable {
    let editingToken: IOSEpisodeEditingToken
    let structureDigest: SyncWorkStructureDigest
}

struct IOSDeviceSyncClient {
    let coordinator: EpisodeSyncCoordinator
    let sessionID: SyncEditSessionID
}

struct IOSDeviceSyncClientKey: Hashable {
    let localWorkingCopyID: LocalWorkingCopyID
    let syncKey: EpisodeSyncKey
}

struct IOSPendingDeviceSyncConflictResolution {
    let key: EpisodeSyncKey
    let conflict: EpisodeConflict
    let content: String
}

struct IOSDeviceSyncMergeRecoveryRecord: Codable, Hashable, Sendable {
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

protocol IOSDeviceSyncMergeRecoveryStoring: Sendable {
    func load(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) async throws -> IOSDeviceSyncMergeRecoveryRecord?
    func save(_ record: IOSDeviceSyncMergeRecoveryRecord) async throws
    func remove(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) async throws
}

actor IOSInMemoryDeviceSyncMergeRecoveryStore: IOSDeviceSyncMergeRecoveryStoring {
    private var records: [String: IOSDeviceSyncMergeRecoveryRecord] = [:]

    func load(
        localWorkingCopyID: LocalWorkingCopyID,
        key: EpisodeSyncKey
    ) -> IOSDeviceSyncMergeRecoveryRecord? {
        records[Self.storageKey(localWorkingCopyID: localWorkingCopyID, key: key)]
    }

    func save(_ record: IOSDeviceSyncMergeRecoveryRecord) {
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

actor IOSFileDeviceSyncMergeRecoveryStore: IOSDeviceSyncMergeRecoveryStoring {
    static let maximumRecordBytes = 64 * 1024 * 1024

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
    ) throws -> IOSDeviceSyncMergeRecoveryRecord? {
        try validateFixedRoot()
        let url = recordURL(localWorkingCopyID: localWorkingCopyID, key: key)
        guard let status = try pathStatus(at: url) else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
        }
        let data = try readBoundedRegularFile(at: url)
        let record = try decoder.decode(IOSDeviceSyncMergeRecoveryRecord.self, from: data)
        guard record.localWorkingCopyID == localWorkingCopyID, record.key == key else {
            throw IOSDeviceSyncMergeRecoveryStoreError.identityMismatch
        }
        try validate(record)
        return record
    }

    func save(_ record: IOSDeviceSyncMergeRecoveryRecord) throws {
        try validateFixedRoot()
        try validate(record)
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw IOSDeviceSyncMergeRecoveryStoreError.recordTooLarge
        }
        let destination = recordURL(localWorkingCopyID: record.localWorkingCopyID, key: record.key)
        if let status = try pathStatus(at: destination), status.st_mode & S_IFMT != S_IFREG {
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
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
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
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
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
    }

    private func pathStatus(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return info
        }
        guard errno == ENOENT else {
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
        }
        return nil
    }

    private func readBoundedRegularFile(at url: URL) throws -> Data {
        try validateRegularNonSymlinkPath(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Self.maximumRecordBytes else {
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
        }
        let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecordBytes else {
            throw IOSDeviceSyncMergeRecoveryStoreError.recordTooLarge
        }
        return data
    }

    private func validateRegularNonSymlinkPath(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
        }
    }

    private func validate(_ record: IOSDeviceSyncMergeRecoveryRecord) throws {
        guard record.content.utf8.count <= EpisodeRevision.maximumContentUTF8Bytes,
              record.localParentRevisionID != record.remoteParentRevisionID,
              record.contentDigest == SyncContentDigest(content: record.content) else {
            throw IOSDeviceSyncMergeRecoveryStoreError.invalidFile
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
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
        }

        var requestedInfo = stat()
        if lstat(requested.path, &requestedInfo) == 0,
           requestedInfo.st_mode & S_IFMT == S_IFLNK {
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
        }

        var existingAncestor = requested
        var missingComponents: [String] = []
        while true {
            var info = stat()
            if lstat(existingAncestor.path, &info) == 0 {
                break
            }
            guard errno == ENOENT, existingAncestor.path != "/" else {
                throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = existingAncestor.deletingLastPathComponent()
        }

        guard let resolvedPointer = realpath(existingAncestor.path, nil) else {
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        defer { free(resolvedPointer) }
        var canonical = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
            .standardizedFileURL
        for component in missingComponents {
            canonical.appendPathComponent(component, isDirectory: true)
        }
        guard canonical.path != "/", canonical.pathComponents.count >= 4 else {
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        do {
            try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        } catch {
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
        }
        var rootInfo = stat()
        guard lstat(canonical.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw IOSDeviceSyncMergeRecoveryStoreError.unsafeRoot
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

enum IOSDeviceSyncMergeRecoveryStoreError: Error, Equatable, Sendable {
    case unsafeRoot
    case invalidFile
    case identityMismatch
    case recordTooLarge
}

struct IOSDeviceSyncForceContinuationConfirmation {
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

struct IOSDeviceSyncConflictDraft: Equatable {
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
            "変更箇所が重なっているため、このiPhoneの本文を下書きにしています。同期先と見比べて統合してください。"
        case .recoveredIntegration:
            "以前に選んだ統合本文を復元しました。現在の2つの変更と見比べ、内容を再確認してから保存してください。"
        }
    }
}
