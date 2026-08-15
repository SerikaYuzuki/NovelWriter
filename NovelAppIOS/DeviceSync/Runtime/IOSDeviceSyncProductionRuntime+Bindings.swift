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
        if let existing = pendingCreateAndBindTasks[descriptor.workID] {
            return try await existing.value
        }
        let task = Task {
            try await self.performCreateAndBindNewWork(
                workingCopyID: workingCopyID,
                descriptor: descriptor,
                allowedEpisodes: allowedEpisodes
            )
        }
        pendingCreateAndBindTasks[descriptor.workID] = task
        do {
            let resolved = try await task.value
            pendingCreateAndBindTasks[descriptor.workID] = nil
            return resolved
        } catch {
            pendingCreateAndBindTasks[descriptor.workID] = nil
            throw error
        }
    }

    private func performCreateAndBindNewWork(
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
                    CloudKitSyncDiagnostic.log("cloud-library startNew ready")
                    return try await services.createAndBindNewWork(
                        locator,
                        proposedDescriptor: descriptor,
                        allowedEpisodeIDs: allowedEpisodes
                    )
                case let .blocked(blocked?):
                    CloudKitSyncDiagnostic.log("cloud-library startNew blocked")
                    _ = try await blocked.prepareAndBindPendingWorkCreation(
                        locator,
                        proposedDescriptor: descriptor,
                        allowedEpisodeIDs: allowedEpisodes
                    )
                    return nil
                case .starting, .blocked(nil):
                    CloudKitSyncDiagnostic.log("cloud-library startNew unavailable")
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
            CloudKitSyncDiagnostic.log("cloud-library startNew failed", error: error)
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
        try await publishInitialNoteSnapshot(
            binding: resolved.binding,
            snapshot: initialSnapshot
        )
    }

    private func publishInitialNoteSnapshot(
        binding: SyncWorkingCopyBinding,
        snapshot: WorkSnapshot
    ) async throws {
        if let existing = pendingWorkPublicationTasks[binding.workID] {
            try await existing.value
            return
        }
        CloudKitSyncDiagnostic.log("cloud-library noteSnapshot begin")
        let task = Task {
            let coordinator = try await makeNoteSyncCoordinator(
                workID: binding.workID,
                localWorkingCopyID: binding.localWorkingCopyID
            )
            _ = try await coordinator.publishLocal(snapshot)
        }
        pendingWorkPublicationTasks[binding.workID] = task
        do {
            try await task.value
            pendingWorkPublicationTasks[binding.workID] = nil
            CloudKitSyncDiagnostic.log("cloud-library noteSnapshot ok")
        } catch {
            pendingWorkPublicationTasks[binding.workID] = nil
            CloudKitSyncDiagnostic.log("cloud-library noteSnapshot failed", error: error)
            throw error
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
