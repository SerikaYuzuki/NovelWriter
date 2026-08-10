import Foundation
import NovelCore
import NovelSync

public enum AppleDeviceSyncBlockReason: String, Codable, Equatable, Sendable {
    case differentCloudAccount
    case accountUnavailable
}

public enum AppleDeviceSyncAvailability: Equatable, Sendable {
    case ready
    case blocked(AppleDeviceSyncBlockReason)
}

public enum AppleDeviceSyncServicesError: Error, Equatable, Sendable {
    case unsafeRoot
    case invalidMetadata
    case metadataTooLarge
    case metadataWriteFailed
    case invalidLocator
    case locatorAlreadyBound
    case bindingNotFound
    case remoteWorkNotFound
    case structureMismatch
    case sourceDocumentMismatch
    case tooManyAllowedEpisodes
    case duplicateAllowedEpisodeID
    case generationOverflow
    case blocked(AppleDeviceSyncBlockReason)
}

/// Appが決める端末内だけの安定locator。pathやbookmarkをCloudKit recordへ送らない。
public struct AppleLocalDocumentLocator: Hashable, Codable, Sendable {
    public static let maximumUTF8Bytes = 4 * 1024

    public let rawValue: String

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Bytes,
              rawValue.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            throw AppleDeviceSyncServicesError.invalidLocator
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(rawValue: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "local document locator is empty, unsafe, or too large"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AppleCloudAccountScope: Codable, Equatable, Sendable {
    let digest: SyncContentDigest

    init(containerIdentifier: String, userRecordName: String) {
        let input = "FUMINIWA-CLOUD-ACCOUNT-SCOPE-V1\n"
            + "\(containerIdentifier.utf8.count):\(containerIdentifier)\n"
            + "\(userRecordName.utf8.count):\(userRecordName)\n"
        digest = SyncContentDigest(content: input)
    }
}

struct AppleDeviceSyncMetadataSnapshot: Sendable {
    let replicaID: SyncReplicaID
    let accountScope: AppleCloudAccountScope?
    let bindings: [AppleLocalDocumentLocator: AppleDeviceSyncBindingSnapshot]
    let engineStateGeneration: UInt64
    let engineState: Data?
}

struct AppleDeviceSyncBindingSnapshot: Equatable, Sendable {
    let binding: SyncWorkingCopyBinding
    let allowedEpisodeIDs: Set<EpisodeID>
}

actor AppleDeviceSyncMetadataStore {
    static let schemaVersion = 1
    static let maximumMetadataBytes = 1 * 1024 * 1024
    static let maximumEngineStateBytes = 512 * 1024
    static let maximumBindingCount = 1024
    static let maximumAllowedEpisodeCount = 4096
    static let metadataFileName = "device-sync-metadata-v1.json"

    private struct BindingRecord: Codable, Sendable {
        let locator: AppleLocalDocumentLocator
        let binding: SyncWorkingCopyBinding
        let allowedEpisodeIDs: [EpisodeID]
    }

    private struct Document: Codable, Sendable {
        var schemaVersion: Int
        var replicaID: SyncReplicaID
        var accountScope: AppleCloudAccountScope?
        var bindings: [BindingRecord]
        var engineStateGeneration: UInt64
        var engineState: Data?
    }

    private let rootURL: URL
    private let metadataURL: URL
    private let fileManager: FileManager
    private var document: Document

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        let safeRoot = try AppleDeviceSyncMetadataRoot.prepare(
            rootURL,
            fileManager: fileManager
        )
        let metadataURL = safeRoot.appendingPathComponent(Self.metadataFileName, isDirectory: false)
        let loaded: Document
        if fileManager.fileExists(atPath: metadataURL.path) {
            loaded = try Self.loadDocument(from: metadataURL, fileManager: fileManager)
        } else {
            loaded = Document(
                schemaVersion: Self.schemaVersion,
                replicaID: SyncReplicaID(),
                accountScope: nil,
                bindings: [],
                engineStateGeneration: 0,
                engineState: nil
            )
            try Self.persist(
                loaded,
                to: metadataURL,
                rootURL: safeRoot,
                fileManager: fileManager
            )
        }
        try Self.validate(loaded)
        self.rootURL = safeRoot
        self.metadataURL = metadataURL
        self.fileManager = fileManager
        document = loaded
    }

    func snapshot() -> AppleDeviceSyncMetadataSnapshot {
        AppleDeviceSyncMetadataSnapshot(
            replicaID: document.replicaID,
            accountScope: document.accountScope,
            bindings: Dictionary(uniqueKeysWithValues: document.bindings.map {
                ($0.locator, bindingSnapshot(from: $0))
            }),
            engineStateGeneration: document.engineStateGeneration,
            engineState: document.engineState
        )
    }

    func safeRootURL() -> URL {
        rootURL
    }

    func installAccountScope(_ scope: AppleCloudAccountScope) throws -> AppleDeviceSyncMetadataSnapshot {
        if let installed = document.accountScope {
            guard installed == scope else {
                throw AppleDeviceSyncServicesError.blocked(.differentCloudAccount)
            }
            return snapshot()
        }
        guard document.bindings.isEmpty, document.engineState == nil else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        var candidate = document
        candidate.accountScope = scope
        candidate.engineStateGeneration = try incrementedGeneration(candidate.engineStateGeneration)
        try commit(candidate)
        return snapshot()
    }

    func binding(for locator: AppleLocalDocumentLocator) -> SyncWorkingCopyBinding? {
        document.bindings.first(where: { $0.locator == locator })?.binding
    }

    func bindingSnapshot(
        for locator: AppleLocalDocumentLocator
    ) -> AppleDeviceSyncBindingSnapshot? {
        document.bindings
            .first(where: { $0.locator == locator })
            .map(bindingSnapshot)
    }

    func contains(_ binding: SyncWorkingCopyBinding) -> Bool {
        document.bindings.contains(where: { $0.binding == binding })
    }

    func bind(
        _ locator: AppleLocalDocumentLocator,
        to workID: SyncWorkID,
        allowedEpisodeIDs: [EpisodeID]
    ) throws -> AppleDeviceSyncBindingSnapshot {
        guard document.accountScope != nil else {
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        let validatedEpisodeIDs = try validatedAllowedEpisodeIDs(allowedEpisodeIDs)
        if let existing = document.bindings.first(where: { $0.locator == locator }) {
            guard existing.binding.workID == workID else {
                throw AppleDeviceSyncServicesError.locatorAlreadyBound
            }
            return bindingSnapshot(from: existing)
        }
        guard document.bindings.count < Self.maximumBindingCount else {
            throw AppleDeviceSyncServicesError.metadataTooLarge
        }
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        var candidate = document
        candidate.bindings.append(
            BindingRecord(
                locator: locator,
                binding: binding,
                allowedEpisodeIDs: validatedEpisodeIDs
            )
        )
        try commit(candidate)
        return AppleDeviceSyncBindingSnapshot(
            binding: binding,
            allowedEpisodeIDs: Set(validatedEpisodeIDs)
        )
    }

    /// 同じlocatorを別remote workへ付け替える唯一のAPI。旧client/journalとの
    /// identity混同を避けるためLocalWorkingCopyIDも新しくする。
    func rebind(
        _ locator: AppleLocalDocumentLocator,
        to workID: SyncWorkID,
        allowedEpisodeIDs: [EpisodeID]
    ) throws -> AppleDeviceSyncBindingSnapshot {
        guard document.accountScope != nil else {
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        let validatedEpisodeIDs = try validatedAllowedEpisodeIDs(allowedEpisodeIDs)
        guard let index = document.bindings.firstIndex(where: { $0.locator == locator }) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        let replacement = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        var candidate = document
        candidate.bindings[index] = BindingRecord(
            locator: locator,
            binding: replacement,
            allowedEpisodeIDs: validatedEpisodeIDs
        )
        try commit(candidate)
        return AppleDeviceSyncBindingSnapshot(
            binding: replacement,
            allowedEpisodeIDs: Set(validatedEpisodeIDs)
        )
    }

    @discardableResult
    func unbind(_ locator: AppleLocalDocumentLocator) throws -> SyncWorkingCopyBinding? {
        guard let index = document.bindings.firstIndex(where: { $0.locator == locator }) else {
            return nil
        }
        var candidate = document
        let removed = candidate.bindings.remove(at: index).binding
        try commit(candidate)
        return removed
    }

    @discardableResult
    func saveEngineState(_ state: Data, generation: UInt64) throws -> Bool {
        guard generation == document.engineStateGeneration else { return false }
        guard state.count <= Self.maximumEngineStateBytes else {
            throw AppleDeviceSyncServicesError.metadataTooLarge
        }
        var candidate = document
        candidate.engineState = state
        try commit(candidate)
        return true
    }

    @discardableResult
    func invalidateEngineState(expectedGeneration: UInt64) throws -> UInt64 {
        guard expectedGeneration == document.engineStateGeneration else {
            return document.engineStateGeneration
        }
        var candidate = document
        candidate.engineState = nil
        candidate.engineStateGeneration = try incrementedGeneration(candidate.engineStateGeneration)
        try commit(candidate)
        return candidate.engineStateGeneration
    }

    private func commit(_ candidate: Document) throws {
        try Self.validate(candidate)
        try Self.persist(
            candidate,
            to: metadataURL,
            rootURL: rootURL,
            fileManager: fileManager
        )
        document = candidate
    }

    private func incrementedGeneration(_ generation: UInt64) throws -> UInt64 {
        guard generation < UInt64.max else {
            throw AppleDeviceSyncServicesError.generationOverflow
        }
        return generation + 1
    }

    private static func loadDocument(from url: URL, fileManager _: FileManager) throws -> Document {
        do {
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount <= maximumMetadataBytes else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumMetadataBytes else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
            return try makeDecoder().decode(Document.self, from: data)
        } catch let error as AppleDeviceSyncServicesError {
            throw error
        } catch {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
    }

    private static func validate(_ document: Document) throws {
        guard document.schemaVersion == schemaVersion,
              document.bindings.count <= maximumBindingCount,
              document.engineState.map({ $0.count <= maximumEngineStateBytes }) ?? true else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        let locators = document.bindings.map(\.locator)
        let workingCopyIDs = document.bindings.map(\.binding.localWorkingCopyID)
        guard Set(locators).count == locators.count,
              Set(workingCopyIDs).count == workingCopyIDs.count else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        for binding in document.bindings {
            guard binding.allowedEpisodeIDs.count <= maximumAllowedEpisodeCount,
                  Set(binding.allowedEpisodeIDs).count == binding.allowedEpisodeIDs.count else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
        }
        if document.accountScope == nil {
            guard document.bindings.isEmpty, document.engineState == nil else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
        }
    }

    private static func persist(
        _ document: Document,
        to destination: URL,
        rootURL: URL,
        fileManager: FileManager
    ) throws {
        do {
            try validate(document)
            let sorted = Document(
                schemaVersion: document.schemaVersion,
                replicaID: document.replicaID,
                accountScope: document.accountScope,
                bindings: document.bindings
                    .sorted { $0.locator.rawValue < $1.locator.rawValue }
                    .map { binding in
                        BindingRecord(
                            locator: binding.locator,
                            binding: binding.binding,
                            allowedEpisodeIDs: binding.allowedEpisodeIDs.sorted {
                                $0.rawValue.uuidString < $1.rawValue.uuidString
                            }
                        )
                    },
                engineStateGeneration: document.engineStateGeneration,
                engineState: document.engineState
            )
            let data = try makeEncoder().encode(sorted)
            guard data.count <= maximumMetadataBytes else {
                throw AppleDeviceSyncServicesError.metadataTooLarge
            }
            if fileManager.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw AppleDeviceSyncServicesError.unsafeRoot
                }
            }
            let temporary = rootURL.appendingPathComponent(
                ".device-sync-metadata-\(UUID().uuidString).tmp",
                isDirectory: false
            )
            do {
                try data.write(to: temporary, options: .withoutOverwriting)
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
        } catch let error as AppleDeviceSyncServicesError {
            throw error
        } catch {
            throw AppleDeviceSyncServicesError.metadataWriteFailed
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func validatedAllowedEpisodeIDs(
        _ episodeIDs: [EpisodeID]
    ) throws -> [EpisodeID] {
        guard episodeIDs.count <= Self.maximumAllowedEpisodeCount else {
            throw AppleDeviceSyncServicesError.tooManyAllowedEpisodes
        }
        guard Set(episodeIDs).count == episodeIDs.count else {
            throw AppleDeviceSyncServicesError.duplicateAllowedEpisodeID
        }
        return episodeIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    private func bindingSnapshot(
        from record: BindingRecord
    ) -> AppleDeviceSyncBindingSnapshot {
        AppleDeviceSyncBindingSnapshot(
            binding: record.binding,
            allowedEpisodeIDs: Set(record.allowedEpisodeIDs)
        )
    }
}
