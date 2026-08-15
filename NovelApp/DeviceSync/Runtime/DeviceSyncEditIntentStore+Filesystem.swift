#if canImport(NovelSyncCloudKit)
import Darwin
import Foundation
import NovelCore
import NovelSync

extension FileDeviceSyncEditIntentStore {
    func readEnvelopeIfPresent(at url: URL) throws -> Envelope? {
        try validateFixedRoot()
        guard let status = try pathStatus(at: url) else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        return try readEnvelope(at: url)
    }

    func readEnvelope(at url: URL) throws -> Envelope {
        let envelope = try decoder.decode(Envelope.self, from: readBoundedRegularFile(at: url))
        guard envelope.protocolVersion == Envelope.currentProtocolVersion else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        if let marker = envelope.marker {
            try validate(marker)
            guard try encoder.encode(marker).count <= Self.maximumMarkerBytes else {
                throw DeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        guard envelope.preservedMarkers.count <= 3 else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        for marker in envelope.preservedMarkers {
            try validate(marker)
            guard try encoder.encode(marker).count <= Self.maximumMarkerBytes else {
                throw DeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        try envelope.committedPackage.map(validate)
        try envelope.preparedPackage.map(validate)
        try validateFixedRoot()
        return envelope
    }

    func writeEnvelope(_ envelope: Envelope, to url: URL) throws {
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        if let status = try pathStatus(at: url) {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw DeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        try data.write(to: url, options: .atomic)
        try validateFixedRoot()
        try validateRegularNonSymlinkPath(url)
    }

    func validateScope(
        _ envelope: Envelope,
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) throws {
        let matches: (String, UUID, EpisodeID) -> Bool = {
            $0 == workingCopyIdentity && $1 == documentID && $2 == episodeID
        }
        if let marker = envelope.marker {
            guard matches(marker.workingCopyIdentity, marker.documentID, marker.episodeID) else {
                throw DeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        for marker in envelope.preservedMarkers {
            guard matches(marker.workingCopyIdentity, marker.documentID, marker.episodeID) else {
                throw DeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        for checkpoint in [envelope.committedPackage, envelope.preparedPackage].compactMap(\.self) {
            guard matches(checkpoint.workingCopyIdentity, checkpoint.documentID, checkpoint.episodeID) else {
                throw DeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
    }

    func validateFixedRoot() throws {
        var info = stat()
        guard lstat(rootURL.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              FileDeviceSyncMergeRecoveryStore.RootIdentity(info) == rootIdentity else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
    }

    func pathStatus(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return info
        }
        guard errno == ENOENT else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        return nil
    }

    func readBoundedRegularFile(at url: URL) throws -> Data {
        try validateRegularNonSymlinkPath(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DeviceSyncLocalPersistenceError.invalidEditIntent }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Self.maximumEnvelopeBytes else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        let data = try handle.read(upToCount: Self.maximumEnvelopeBytes + 1) ?? Data()
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        return data
    }

    func validateRegularNonSymlinkPath(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
    }

    func removeRegularFile(at url: URL) throws {
        try validateRegularNonSymlinkPath(url)
        try fileManager.removeItem(at: url)
    }

    func fileURL(for marker: DeviceSyncEditIntentMarker) -> URL {
        fileURL(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
    }

    func fileURL(for checkpoint: DeviceSyncPackageCheckpoint) -> URL {
        fileURL(
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
    }

    func fileURL(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) -> URL {
        let prefix = filePrefix(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        return rootURL.appendingPathComponent("\(prefix)slots.json")
    }

    func filePrefix(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) -> String {
        let key = "FUMINIWA-DEVICE-SYNC-EDIT-INTENT-V1\n\(workingCopyIdentity)\n"
            + "\(documentID.uuidString)\n\(episodeID.rawValue.uuidString)"
        return "\(SyncContentDigest(content: key).rawValue)-"
    }

    func validate(_ marker: DeviceSyncEditIntentMarker) throws {
        let resolvedSequences = marker.resolvesPreservedSequences ?? []
        let hasValidResolutionReferences = marker.resolvesPreservedSequences == nil
            || (!resolvedSequences.isEmpty && resolvedSequences.count <= 3)
        let hasCompleteRemoteScope = (marker.localWorkingCopyID == nil) == (marker.workID == nil)
        let hasUniqueResolutionReferences = Set(resolvedSequences).count == resolvedSequences.count
        let hasPositiveResolutionReferences = resolvedSequences.allSatisfy { $0 > 0 }
        guard marker.protocolVersion == DeviceSyncEditIntentMarker.currentProtocolVersion,
              marker.mutationSequence > 0,
              marker.content.utf8.count <= 1_048_576,
              marker.contentDigest == SyncContentDigest(content: marker.content),
              (marker.acceptedPriorPackageDigests?.count ?? 0) <= 4096,
              hasValidResolutionReferences,
              hasUniqueResolutionReferences,
              hasPositiveResolutionReferences,
              hasCompleteRemoteScope else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
    }

    func validate(_ checkpoint: DeviceSyncPackageCheckpoint) throws {
        guard checkpoint.protocolVersion == DeviceSyncPackageCheckpoint.currentProtocolVersion,
              !checkpoint.workingCopyIdentity.isEmpty else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
    }

    func packageCheckpoint(
        for marker: DeviceSyncEditIntentMarker,
        sequence: UInt64,
        contentDigest: SyncContentDigest
    ) -> DeviceSyncPackageCheckpoint {
        DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID,
            sequence: sequence,
            contentDigest: contentDigest,
            containsLocalEditIntent: false
        )
    }

    static func prepareAnchoredRoot(
        _ requestedURL: URL,
        trustedAncestorURL: URL,
        fileManager: FileManager
    ) throws -> (url: URL, identity: FileDeviceSyncMergeRecoveryStore.RootIdentity) {
        let requested = requestedURL.standardizedFileURL
        let trusted = trustedAncestorURL.standardizedFileURL
        guard requestedURL.isFileURL,
              trustedAncestorURL.isFileURL,
              requested.path.hasPrefix(trusted.path + "/"),
              let resolvedPointer = realpath(trusted.path, nil) else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
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
                    throw DeviceSyncLocalPersistenceError.invalidEditIntent
                }
            } else {
                guard errno == ENOENT else {
                    throw DeviceSyncLocalPersistenceError.invalidEditIntent
                }
                do {
                    try fileManager.createDirectory(at: canonical, withIntermediateDirectories: false)
                } catch {
                    throw DeviceSyncLocalPersistenceError.invalidEditIntent
                }
            }
        }
        var rootInfo = stat()
        guard lstat(canonical.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw DeviceSyncLocalPersistenceError.invalidEditIntent
        }
        return (canonical, FileDeviceSyncMergeRecoveryStore.RootIdentity(rootInfo))
    }
}

#endif
