import Foundation
import NovelCore
import NovelSync

extension AppleDeviceSyncMetadataStore {
    func commit(_ candidate: AppleDeviceSyncMetadataDocument) throws {
        try Self.validate(candidate)
        try Self.persist(
            candidate,
            to: metadataURL,
            rootURL: rootURL,
            fileManager: fileManager
        )
        document = candidate
    }

    static func loadDocument(
        from url: URL,
        fileManager _: FileManager
    ) throws -> AppleDeviceSyncMetadataDocument {
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
            return try JSONDecoder().decode(AppleDeviceSyncMetadataDocument.self, from: data)
        } catch let error as AppleDeviceSyncServicesError {
            throw error
        } catch {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
    }

    static func validate(_ document: AppleDeviceSyncMetadataDocument) throws {
        guard document.schemaVersion == schemaVersion,
              document.bindings.count <= maximumBindingCount,
              document.pendingWorkCreations.count <= maximumPendingWorkCreationCount,
              document.pendingLibraryOpens.count <= maximumPendingLibraryOpenCount,
              document.cachedLibraryEntries.count <= maximumCachedLibraryEntryCount,
              document.engineState.map({ $0.count <= maximumEngineStateBytes }) ?? true else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        let locators = document.bindings.map(\.locator)
        let workingCopyIDs = document.bindings.map(\.binding.localWorkingCopyID)
        let pendingLocators = document.pendingWorkCreations.map(\.locator)
        let pendingWorkIDs = document.pendingWorkCreations.map(\.descriptor.workID)
        let pendingOpenLocators = document.pendingLibraryOpens.map(\.locator)
        let pendingOpenTokens = document.pendingLibraryOpens.map(\.token)
        let pendingOpenWorkIDs = document.pendingLibraryOpens.map(\.entry.workID)
        let cachedWorkIDs = document.cachedLibraryEntries.map(\.workID)
        guard Set(locators).count == locators.count,
              Set(workingCopyIDs).count == workingCopyIDs.count,
              Set(pendingLocators).count == pendingLocators.count,
              Set(pendingWorkIDs).count == pendingWorkIDs.count,
              Set(pendingOpenLocators).count == pendingOpenLocators.count,
              Set(pendingOpenTokens).count == pendingOpenTokens.count,
              Set(pendingOpenWorkIDs).count == pendingOpenWorkIDs.count,
              Set(cachedWorkIDs).count == cachedWorkIDs.count else {
            throw AppleDeviceSyncServicesError.invalidMetadata
        }
        try validateBindings(document.bindings)
        try validatePendingWorkCreations(document)
        try validatePendingLibraryOpens(document)
        try validateCachedLibraryEntries(document.cachedLibraryEntries)
        if document.accountScope == nil {
            guard document.bindings.isEmpty,
                  document.pendingWorkCreations.isEmpty,
                  document.pendingLibraryOpens.isEmpty,
                  document.cachedLibraryEntries.isEmpty,
                  document.engineState == nil else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
        }
    }

    static func persist(
        _ document: AppleDeviceSyncMetadataDocument,
        to destination: URL,
        rootURL: URL,
        fileManager: FileManager
    ) throws {
        do {
            try validate(document)
            let data = try encodedSortedDocument(document)
            guard data.count <= maximumMetadataBytes else {
                throw AppleDeviceSyncServicesError.metadataTooLarge
            }
            try validateDestination(destination, fileManager: fileManager)
            try replaceAtomically(
                destination,
                with: data,
                rootURL: rootURL,
                fileManager: fileManager
            )
        } catch let error as AppleDeviceSyncServicesError {
            throw error
        } catch {
            throw AppleDeviceSyncServicesError.metadataWriteFailed
        }
    }

    private static func validateBindings(
        _ bindings: [AppleDeviceSyncBindingRecord]
    ) throws {
        for binding in bindings {
            guard binding.allowedEpisodeIDs.count <= maximumAllowedEpisodeCount,
                  Set(binding.allowedEpisodeIDs).count == binding.allowedEpisodeIDs.count else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
        }
    }

    private static func validatePendingWorkCreations(
        _ document: AppleDeviceSyncMetadataDocument
    ) throws {
        for pending in document.pendingWorkCreations {
            guard pending.allowedEpisodeIDs.count <= maximumAllowedEpisodeCount,
                  Set(pending.allowedEpisodeIDs).count == pending.allowedEpisodeIDs.count,
                  pending.descriptor.title.utf8.count
                  <= CloudKitRecordCodec.maximumWorkTitleUTF8Bytes else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
            if let binding = document.bindings.first(where: { $0.locator == pending.locator }) {
                guard binding.binding.workID == pending.descriptor.workID,
                      binding.allowedEpisodeIDs == pending.allowedEpisodeIDs else {
                    throw AppleDeviceSyncServicesError.invalidMetadata
                }
            }
        }
    }

    private static func validatePendingLibraryOpens(
        _ document: AppleDeviceSyncMetadataDocument
    ) throws {
        for pending in document.pendingLibraryOpens {
            do {
                try pending.entry.validate()
            } catch {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
            guard pending.entry.title.utf8.count <= CloudKitRecordCodec.maximumWorkTitleUTF8Bytes else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
            if let binding = document.bindings.first(where: { $0.locator == pending.locator }) {
                guard binding.binding.workID == pending.entry.workID else {
                    throw AppleDeviceSyncServicesError.invalidMetadata
                }
            }
        }
    }

    private static func validateCachedLibraryEntries(
        _ entries: [SyncWorkLibraryEntry]
    ) throws {
        for entry in entries {
            do {
                try entry.validate()
            } catch {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
            guard entry.title.utf8.count <= CloudKitRecordCodec.maximumWorkTitleUTF8Bytes else {
                throw AppleDeviceSyncServicesError.invalidMetadata
            }
        }
    }

    private static func encodedSortedDocument(
        _ document: AppleDeviceSyncMetadataDocument
    ) throws -> Data {
        let sorted = AppleDeviceSyncMetadataDocument(
            schemaVersion: document.schemaVersion,
            replicaID: document.replicaID,
            accountScope: document.accountScope,
            bindings: sortedBindings(document.bindings),
            pendingWorkCreations: sortedPendingWorkCreations(document.pendingWorkCreations),
            pendingLibraryOpens: sortedPendingLibraryOpens(document.pendingLibraryOpens),
            cachedLibraryEntries: sortedCachedLibraryEntries(document.cachedLibraryEntries),
            engineStateGeneration: document.engineStateGeneration,
            engineState: document.engineState
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(sorted)
    }

    private static func sortedBindings(
        _ bindings: [AppleDeviceSyncBindingRecord]
    ) -> [AppleDeviceSyncBindingRecord] {
        bindings.sorted { $0.locator.rawValue < $1.locator.rawValue }.map { binding in
            AppleDeviceSyncBindingRecord(
                locator: binding.locator,
                binding: binding.binding,
                allowedEpisodeIDs: sortedEpisodeIDs(binding.allowedEpisodeIDs)
            )
        }
    }

    private static func sortedPendingWorkCreations(
        _ pending: [ApplePendingWorkCreationRecord]
    ) -> [ApplePendingWorkCreationRecord] {
        pending.sorted { $0.locator.rawValue < $1.locator.rawValue }.map { intent in
            ApplePendingWorkCreationRecord(
                locator: intent.locator,
                descriptor: intent.descriptor,
                allowedEpisodeIDs: sortedEpisodeIDs(intent.allowedEpisodeIDs)
            )
        }
    }

    private static func sortedPendingLibraryOpens(
        _ pending: [ApplePendingLibraryOpenRecord]
    ) -> [ApplePendingLibraryOpenRecord] {
        pending.sorted {
            $0.entry.workID.rawValue.uuidString < $1.entry.workID.rawValue.uuidString
        }
    }

    private static func sortedCachedLibraryEntries(
        _ entries: [SyncWorkLibraryEntry]
    ) -> [SyncWorkLibraryEntry] {
        entries.sorted { $0.workID.rawValue.uuidString < $1.workID.rawValue.uuidString }
    }

    private static func sortedEpisodeIDs(_ episodeIDs: [EpisodeID]) -> [EpisodeID] {
        episodeIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    private static func validateDestination(
        _ destination: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
    }

    private static func replaceAtomically(
        _ destination: URL,
        with data: Data,
        rootURL: URL,
        fileManager: FileManager
    ) throws {
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
    }
}
