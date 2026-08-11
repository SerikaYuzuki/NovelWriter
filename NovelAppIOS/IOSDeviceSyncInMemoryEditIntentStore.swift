import Foundation
import NovelCore
import NovelSync

actor IOSInMemoryDeviceSyncEditIntentStore: IOSDeviceSyncEditIntentStoring {
    private struct Scope: Hashable {
        let workingCopyIdentity: String
        let documentID: UUID
        let episodeID: EpisodeID

        init(
            workingCopyIdentity: String,
            documentID: UUID,
            episodeID: EpisodeID
        ) {
            self.workingCopyIdentity = workingCopyIdentity
            self.documentID = documentID
            self.episodeID = episodeID
        }

        init(_ marker: IOSDeviceSyncEditIntentMarker) {
            self.init(
                workingCopyIdentity: marker.workingCopyIdentity,
                documentID: marker.documentID,
                episodeID: marker.episodeID
            )
        }

        init(_ checkpoint: IOSDeviceSyncPackageCheckpoint) {
            self.init(
                workingCopyIdentity: checkpoint.workingCopyIdentity,
                documentID: checkpoint.documentID,
                episodeID: checkpoint.episodeID
            )
        }
    }

    private struct Envelope {
        var marker: IOSDeviceSyncEditIntentMarker?
        var preservedMarkers: [IOSDeviceSyncEditIntentMarker]
        var committedPackage: IOSDeviceSyncPackageCheckpoint?
        var preparedPackage: IOSDeviceSyncPackageCheckpoint?

        init(
            marker: IOSDeviceSyncEditIntentMarker? = nil,
            preservedMarkers: [IOSDeviceSyncEditIntentMarker] = [],
            committedPackage: IOSDeviceSyncPackageCheckpoint? = nil,
            preparedPackage: IOSDeviceSyncPackageCheckpoint? = nil
        ) {
            self.marker = marker
            self.preservedMarkers = preservedMarkers
            self.committedPackage = committedPackage
            self.preparedPackage = preparedPackage
        }

        var snapshot: IOSDeviceSyncLocalPersistenceSnapshot {
            IOSDeviceSyncLocalPersistenceSnapshot(
                marker: marker,
                preservedMarkers: preservedMarkers,
                committedPackage: committedPackage,
                preparedPackage: preparedPackage
            )
        }

        var isEmpty: Bool {
            marker == nil && preservedMarkers.isEmpty && committedPackage == nil && preparedPackage == nil
        }
    }

    private var envelopes: [Scope: Envelope] = [:]
}

extension IOSInMemoryDeviceSyncEditIntentStore {
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
        try validate(marker)
        let scope = Scope(marker)
        var envelope = envelopes[scope] ?? Envelope()
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
            envelope.committedPackage = checkpoint(
                scope: scope,
                sequence: marker.mutationSequence - 1,
                contentDigest: baselinePackageDigest
            )
        }
        envelope.marker = marker
        envelopes[scope] = envelope
        return marker
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [IOSDeviceSyncEditIntentMarker] {
        let envelope = envelopes[Scope(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )] ?? Envelope()
        try envelope.preservedMarkers.forEach(validate)
        try envelope.marker.map(validate)
        return envelope.marker.map { [$0] } ?? []
    }

    func remove(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        let scope = Scope(marker)
        guard var envelope = envelopes[scope] else { return }
        if envelope.marker == marker {
            envelope.marker = nil
        } else {
            envelope.preservedMarkers.removeAll { $0 == marker }
        }
        envelopes[scope] = envelope.isEmpty ? nil : envelope
    }

    func preparePackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try validate(checkpoint)
        let scope = Scope(checkpoint)
        var envelope = envelopes[scope] ?? Envelope()
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
        envelopes[scope] = envelope
    }

    func commitPackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try validate(checkpoint)
        let scope = Scope(checkpoint)
        guard var envelope = envelopes[scope], envelope.preparedPackage == checkpoint else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        envelope.committedPackage = checkpoint
        envelope.preparedPackage = nil
        envelopes[scope] = envelope
    }

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let envelope = envelopes[Scope(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )] ?? Envelope()
        try envelope.preservedMarkers.forEach(validate)
        try envelope.marker.map(validate)
        try envelope.committedPackage.map(validate)
        try envelope.preparedPackage.map(validate)
        return envelope.snapshot
    }

    func preserveForReview(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try validate(marker)
        let scope = Scope(marker)
        guard var envelope = envelopes[scope], envelope.marker == marker else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        if !envelope.preservedMarkers.contains(marker) {
            guard envelope.preservedMarkers.count < 3 else {
                throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
            }
            envelope.preservedMarkers.append(marker)
        }
        envelope.marker = nil
        envelopes[scope] = envelope
    }

    func removePreservedForReview(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        expected: [IOSDeviceSyncEditIntentMarker],
        expectedResolvingMarker: IOSDeviceSyncEditIntentMarker
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let scope = Scope(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        let expectedSequences = expected.map(\.mutationSequence)
        guard !expected.isEmpty,
              var envelope = envelopes[scope],
              envelope.preservedMarkers == expected,
              envelope.marker == expectedResolvingMarker,
              expectedResolvingMarker.resolvesPreservedSequences == expectedSequences else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        try expected.forEach(validate)
        envelope.preservedMarkers = []
        envelope.marker = nil
        envelopes[scope] = envelope.isEmpty ? nil : envelope
        return envelope.snapshot
    }

    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence: UInt64,
        contentDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let scope = Scope(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        guard var envelope = envelopes[scope],
              let committed = envelope.committedPackage else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        if committed.sequence > throughSequence {
            return envelope.snapshot
        }
        guard committed.sequence == throughSequence,
              committed.contentDigest == contentDigest else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
        envelope.committedPackage = committed.acknowledgingLocalEditIntent()
        envelopes[scope] = envelope
        return envelope.snapshot
    }

    func reconcilePreparedPackage(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        actualContentDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let scope = Scope(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        var envelope = envelopes[scope] ?? Envelope()
        if let prepared = envelope.preparedPackage {
            if prepared.contentDigest == actualContentDigest {
                envelope.committedPackage = prepared
            }
            envelope.preparedPackage = nil
            envelopes[scope] = envelope.isEmpty ? nil : envelope
        }
        return envelope.snapshot
    }

    private func validate(_ marker: IOSDeviceSyncEditIntentMarker) throws {
        let resolvedSequences = marker.resolvesPreservedSequences ?? []
        let hasValidResolutionReferences = marker.resolvesPreservedSequences == nil
            || (!resolvedSequences.isEmpty && resolvedSequences.count <= 3)
        let hasCompleteRemoteScope = (marker.localWorkingCopyID == nil) == (marker.workID == nil)
        let hasUniqueResolutionReferences = Set(resolvedSequences).count == resolvedSequences.count
        let hasPositiveResolutionReferences = resolvedSequences.allSatisfy { $0 > 0 }
        guard marker.protocolVersion == IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
              marker.mutationSequence > 0,
              marker.content.utf8.count <= 1_048_576,
              marker.contentDigest == SyncContentDigest(content: marker.content),
              (marker.acceptedPriorPackageDigests?.count ?? 0) <= 4096,
              hasValidResolutionReferences,
              hasUniqueResolutionReferences,
              hasPositiveResolutionReferences,
              hasCompleteRemoteScope else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
    }

    private func validate(_ checkpoint: IOSDeviceSyncPackageCheckpoint) throws {
        guard checkpoint.protocolVersion == IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
              !checkpoint.workingCopyIdentity.isEmpty else {
            throw IOSDeviceSyncLocalPersistenceError.invalidEditIntent
        }
    }

    private func checkpoint(
        scope: Scope,
        sequence: UInt64,
        contentDigest: SyncContentDigest
    ) -> IOSDeviceSyncPackageCheckpoint {
        IOSDeviceSyncPackageCheckpoint(
            protocolVersion: IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: scope.workingCopyIdentity,
            documentID: scope.documentID,
            episodeID: scope.episodeID,
            sequence: sequence,
            contentDigest: contentDigest,
            containsLocalEditIntent: false
        )
    }
}
