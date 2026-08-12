#if canImport(NovelSyncCloudKit)
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

extension IOSDeviceSyncProductionRuntimeBox {
    func resolveLocalWork(
        workingCopyID: IOSPrivateDocumentID,
        localSourceDocumentID _: UUID
    ) async throws -> IOSDeviceSyncBindingResolution? {
        let locator = try Self.locator(for: workingCopyID)
        guard try hasSafePackageForResolution(workingCopyID, locator: locator),
              isLocallyBound(locator) else { return nil }
        guard let local = try await localBootstrap.resolveLocal(locator) else { return nil }
        knownBoundLocators.insert(locator)
        return Self.localOnlyResolution(from: local, remoteAvailability: .temporarilyOffline)
    }

    func resolve(
        workingCopyID: IOSPrivateDocumentID,
        localSourceDocumentID: UUID
    ) async throws -> IOSDeviceSyncBindingResolution? {
        let locator = try Self.locator(for: workingCopyID)
        guard try hasSafePackageForResolution(workingCopyID, locator: locator),
              isLocallyBound(locator) else { return nil }
        await retryRemoteBootstrapIfNeeded()
        switch state {
        case let .ready(services):
            let resolution: IOSDeviceSyncBindingResolution? = try await privateWorkingCopyLocation
                .performWithAttestedPackage(for: workingCopyID) {
                    do {
                        guard let resolved = try await services.resolve(
                            locator,
                            localSourceDocumentID: localSourceDocumentID
                        ) else { return nil }
                        return IOSDeviceSyncBindingResolution(
                            binding: resolved.binding,
                            descriptor: resolved.descriptor,
                            journal: resolved.journal,
                            workJournal: resolved.workJournal,
                            allowedEpisodeIDs: resolved.allowedEpisodeIDs
                        )
                    } catch where Self.permitsLocalResolutionFallback(for: error) {
                        let local = try await services.resolveLocal(locator)
                        return Self.localOnlyResolution(
                            from: local,
                            remoteAvailability: Self.remoteAvailability(for: error)
                        )
                    }
                }
            knownBoundLocators.insert(locator)
            return resolution
        case .starting:
            _ = try privateWorkingCopyLocation.attestPackage(for: workingCopyID)
            knownBoundLocators.insert(locator)
            let local = try await localBootstrap.resolveLocal(locator)
            return Self.localOnlyResolution(from: local, remoteAvailability: .temporarilyOffline)
        case let .blocked(blocked):
            _ = try privateWorkingCopyLocation.attestPackage(for: workingCopyID)
            let resolution: AppleLocalResolvedWorkingCopy? = if let blocked {
                try await blocked.resolveLocal(locator)
            } else {
                try await localBootstrap.resolveLocal(locator)
            }
            knownBoundLocators.insert(locator)
            return Self.localOnlyResolution(
                from: resolution,
                remoteAvailability: Self.remoteAvailability(for: blocked)
            )
        }
    }

    func hasSafePackageForResolution(
        _ workingCopyID: IOSPrivateDocumentID,
        locator: AppleLocalDocumentLocator
    ) throws -> Bool {
        do {
            _ = try privateWorkingCopyLocation.attestPackage(for: workingCopyID)
            return true
        } catch {
            switch localBootstrap.localStatus(for: locator) {
            case .unbound:
                return false
            case .bound, .boundAndBlocked:
                throw EpisodeSyncTransportError.unavailable
            }
        }
    }

    func isLocallyBound(_ locator: AppleLocalDocumentLocator) -> Bool {
        if knownBoundLocators.contains(locator) {
            return true
        }
        switch localBootstrap.localStatus(for: locator) {
        case .unbound:
            return false
        case .bound, .boundAndBlocked:
            return true
        }
    }

    func candidates(
        workingCopyID: IOSPrivateDocumentID,
        sourceDocumentID: UUID,
        digest: SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor] {
        _ = try Self.locator(for: workingCopyID)
        let services = try readyServices()
        return try await privateWorkingCopyLocation.performWithAttestedPackage(for: workingCopyID) {
            try await services.workCandidates(
                sourceDocumentIDHint: sourceDocumentID,
                matching: digest
            )
        }
    }

    func startNew(
        workingCopyID: IOSPrivateDocumentID,
        descriptor: SyncWorkDescriptor,
        allowedEpisodes: [EpisodeID]
    ) async throws -> AppleResolvedWorkingCopy? {
        let locator = try Self.locator(for: workingCopyID)
        guard try locator == AppleLocalDocumentLocator.cloudLibrary(workID: descriptor.workID) else {
            throw EpisodeSyncTransportError.unavailable
        }
        if isLocallyBound(locator) {
            knownBoundLocators.insert(locator)
        }
        let resolved: AppleResolvedWorkingCopy?
        do {
            resolved = try await privateWorkingCopyLocation.performWithAttestedPackage(
                for: workingCopyID
            ) {
                switch await self.state {
                case let .ready(services):
                    return try await services.createAndBindNewWork(
                        locator,
                        proposedDescriptor: descriptor,
                        allowedEpisodeIDs: allowedEpisodes
                    )
                case let .blocked(blocked?):
                    _ = try await blocked.prepareAndBindPendingWorkCreation(
                        locator,
                        proposedDescriptor: descriptor,
                        allowedEpisodeIDs: allowedEpisodes
                    )
                    return nil
                case .starting, .blocked(nil):
                    throw EpisodeSyncTransportError.unavailable
                }
            }
        } catch {
            let liveStatus: AppleDeviceSyncLocalBindingStatus = switch state {
            case let .ready(services):
                await services.localStatus(for: locator)
            case let .blocked(blocked?):
                await blocked.localStatus(for: locator)
            case .starting, .blocked(nil):
                .unbound
            }
            _ = recordCreationFailureLocalBinding(locator, status: liveStatus)
            throw error
        }
        _ = recordKnownLocalBinding(locator)
        return resolved
    }

    func resumeInitialWorkPublication(
        workingCopyID: IOSPrivateDocumentID,
        descriptor: SyncWorkDescriptor,
        allowedEpisodes: [EpisodeID],
        initialSnapshot: WorkSnapshot
    ) async throws {
        guard let resolved = try await startNew(
            workingCopyID: workingCopyID,
            descriptor: descriptor,
            allowedEpisodes: allowedEpisodes
        ) else {
            throw EpisodeSyncTransportError.unavailable
        }
        try await resumeInitialWorkPublication(
            binding: resolved.binding,
            journal: resolved.workJournal,
            transport: self,
            initialSnapshot: initialSnapshot,
            at: Date()
        )
    }

    func resumeInitialWorkPublication(
        binding: SyncWorkingCopyBinding,
        journal: any WorkSyncJournal,
        transport: any WorkSyncTransport,
        initialSnapshot: WorkSnapshot,
        at date: Date
    ) async throws {
        if let existing = pendingWorkPublicationTasks[binding.workID] {
            try await existing.value
            return
        }
        let replicaID = localBootstrap.replicaID
        let task = Task {
            let coordinator = WorkSyncCoordinator(
                workID: binding.workID,
                localWorkingCopyID: binding.localWorkingCopyID,
                replicaID: replicaID,
                sessionID: SyncEditSessionID(),
                transport: transport,
                journal: journal
            )
            if let restored = try await coordinator.restore() {
                guard restored.localHead.snapshot == initialSnapshot else {
                    throw WorkSyncCoordinatorError.packageSnapshotMismatch
                }
                if restored.pendingRevisionCount == 0,
                   restored.reconciliationStatus == .synchronized {
                    return
                }
                guard restored.lastKnownRemoteHead == nil,
                      restored.stagedLocalRevision == nil,
                      restored.pendingRemoteMaterialization == nil,
                      restored.retainedLocalRecoveryRevision == nil,
                      restored.conflictReview == nil,
                      restored.reconciliationStatus == .pending
                      || restored.reconciliationStatus == .offline,
                      restored.pendingRevisionCount > 0,
                      let record = try await journal.load(for: binding.workID),
                      Self.isInitialPublicationLineage(record) else {
                    throw IOSDeviceSyncInitialWorkPublicationError.requiresActiveDocumentPreflight
                }
            } else {
                _ = try await coordinator.bootstrapLocalSnapshot(initialSnapshot, at: date)
            }
            _ = try await coordinator.synchronize(at: date)
        }
        pendingWorkPublicationTasks[binding.workID] = task
        do {
            try await task.value
            pendingWorkPublicationTasks[binding.workID] = nil
        } catch {
            pendingWorkPublicationTasks[binding.workID] = nil
            throw error
        }
    }

    private static func isInitialPublicationLineage(_ record: WorkSyncJournalRecord) -> Bool {
        guard record.lastKnownRemoteHead == nil,
              !record.outbox.isEmpty,
              record.outbox.last == record.localHead,
              record.outbox.first?.parentRevisionIDs.isEmpty == true else { return false }
        return zip(record.outbox.dropFirst(), record.outbox).allSatisfy { pair in
            pair.0.parentRevisionIDs == [pair.1.revisionID]
        }
    }

    @discardableResult
    func recordCreationFailureLocalBinding(
        _ locator: AppleLocalDocumentLocator,
        status: AppleDeviceSyncLocalBindingStatus
    ) -> Bool {
        guard status != .unbound else { return false }
        return recordKnownLocalBinding(locator)
    }

    @discardableResult
    func recordKnownLocalBinding(_ locator: AppleLocalDocumentLocator) -> Bool {
        guard knownBoundLocators.insert(locator).inserted else { return false }
        signalContinuation.yield()
        return true
    }

    func bind(
        workingCopyID: IOSPrivateDocumentID,
        sourceDocumentID: UUID,
        digest: SyncWorkStructureDigest,
        workID: SyncWorkID,
        allowedEpisodes: [EpisodeID]
    ) async throws {
        let locator = try Self.locator(for: workingCopyID)
        let services = try readyServices()
        _ = try await privateWorkingCopyLocation.performWithAttestedPackage(for: workingCopyID) {
            try await services.bind(
                locator,
                to: workID,
                localSourceDocumentID: sourceDocumentID,
                allowedEpisodeIDs: allowedEpisodes,
                matching: digest
            )
        }
        knownBoundLocators.insert(locator)
        signalContinuation.yield()
    }
}

#endif
