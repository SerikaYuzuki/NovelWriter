#if canImport(NovelSyncCloudKit)
import Foundation
import NovelCore
import NovelSync

extension IOSFileDeviceSyncEditIntentStore {
    func save(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        _ = try await save(
            marker,
            baselinePackageDigest: marker.baseContentDigest ?? marker.contentDigest
        )
    }

    func save(
        _ marker: IOSDeviceSyncEditIntentMarker,
        baselinePackageDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncEditIntentMarker {
        try validateFixedRoot()
        try validate(marker)
        guard try encoder.encode(marker).count <= Self.maximumMarkerBytes else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        let destination = fileURL(for: marker)
        if let status = try pathStatus(at: destination) {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        var envelope = try readEnvelopeIfPresent(at: destination) ?? Envelope()
        try validateScope(
            envelope,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        let isExactRetry = envelope.marker == marker
        if let stored = envelope.marker {
            guard isExactRetry || stored.mutationSequence < marker.mutationSequence else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        if let committed = envelope.committedPackage {
            guard isExactRetry || committed.sequence < marker.mutationSequence else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
        } else {
            envelope.committedPackage = packageCheckpoint(
                for: marker,
                sequence: marker.mutationSequence - 1,
                contentDigest: baselinePackageDigest
            )
        }
        envelope.marker = marker
        try writeEnvelope(envelope, to: destination)
        return marker
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [IOSDeviceSyncEditIntentMarker] {
        let url = fileURL(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        guard let envelope = try readEnvelopeIfPresent(at: url) else { return [] }
        try validateScope(
            envelope,
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        return envelope.marker.map { [$0] } ?? []
    }

    func remove(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try validateFixedRoot()
        let url = fileURL(for: marker)
        guard let status = try pathStatus(at: url) else { return }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        var envelope = try readEnvelope(at: url)
        try validateScope(
            envelope,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        if envelope.marker == marker {
            envelope.marker = nil
        } else if let index = envelope.preservedMarkers.firstIndex(of: marker) {
            envelope.preservedMarkers.remove(at: index)
        } else {
            return
        }
        if envelope.isEmpty {
            try removeRegularFile(at: url)
        } else {
            try writeEnvelope(envelope, to: url)
        }
        try validateFixedRoot()
    }

    func preparePackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try validateFixedRoot()
        try validate(checkpoint)
        let url = fileURL(for: checkpoint)
        var envelope = try readEnvelopeIfPresent(at: url) ?? Envelope()
        try validateScope(
            envelope,
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
        if let committed = envelope.committedPackage {
            guard committed == checkpoint || committed.sequence < checkpoint.sequence else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        if let prepared = envelope.preparedPackage {
            guard prepared == checkpoint else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
        }
        envelope.preparedPackage = checkpoint
        try writeEnvelope(envelope, to: url)
    }

    func commitPackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try validateFixedRoot()
        try validate(checkpoint)
        let url = fileURL(for: checkpoint)
        guard var envelope = try readEnvelopeIfPresent(at: url),
              envelope.preparedPackage == checkpoint else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        envelope.committedPackage = checkpoint
        envelope.preparedPackage = nil
        try writeEnvelope(envelope, to: url)
    }

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let url = fileURL(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        guard let envelope = try readEnvelopeIfPresent(at: url) else {
            return Envelope().snapshot
        }
        try validateScope(
            envelope,
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        return envelope.snapshot
    }

    func reconcilePreparedPackage(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        actualContentDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let url = fileURL(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        guard var envelope = try readEnvelopeIfPresent(at: url) else {
            return Envelope().snapshot
        }
        try validateScope(
            envelope,
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        if let prepared = envelope.preparedPackage {
            if prepared.contentDigest == actualContentDigest {
                envelope.committedPackage = prepared
            }
            envelope.preparedPackage = nil
            if envelope.isEmpty {
                try removeRegularFile(at: url)
            } else {
                try writeEnvelope(envelope, to: url)
            }
        }
        return envelope.snapshot
    }

    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence: UInt64,
        contentDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let url = fileURL(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        guard var envelope = try readEnvelopeIfPresent(at: url),
              let committed = envelope.committedPackage else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        try validateScope(
            envelope,
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        if committed.sequence > throughSequence {
            return envelope.snapshot
        }
        guard committed.sequence == throughSequence,
              committed.contentDigest == contentDigest else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        envelope.committedPackage = committed.acknowledgingLocalEditIntent()
        try writeEnvelope(envelope, to: url)
        return envelope.snapshot
    }

    func preserveForReview(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try validateFixedRoot()
        try validate(marker)
        let url = fileURL(for: marker)
        guard var envelope = try readEnvelopeIfPresent(at: url),
              envelope.marker == marker else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        try validateScope(
            envelope,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        if !envelope.preservedMarkers.contains(marker) {
            guard envelope.preservedMarkers.count < 3 else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
            envelope.preservedMarkers.append(marker)
        }
        envelope.marker = nil
        try writeEnvelope(envelope, to: url)
    }

    func removePreservedForReview(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        expected: [IOSDeviceSyncEditIntentMarker],
        expectedResolvingMarker: IOSDeviceSyncEditIntentMarker
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        try validateFixedRoot()
        guard !expected.isEmpty else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        let url = fileURL(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        let expectedSequences = expected.map(\.mutationSequence)
        guard var envelope = try readEnvelopeIfPresent(at: url),
              envelope.preservedMarkers == expected,
              envelope.marker == expectedResolvingMarker,
              expectedResolvingMarker.resolvesPreservedSequences == expectedSequences else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        try validateScope(
            envelope,
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        envelope.preservedMarkers = []
        envelope.marker = nil
        if envelope.isEmpty {
            try removeRegularFile(at: url)
        } else {
            try writeEnvelope(envelope, to: url)
        }
        try validateFixedRoot()
        return envelope.snapshot
    }
}

#endif
