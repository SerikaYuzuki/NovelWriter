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
    ) async throws {
        let services = try readyServices()
        let locator = try Self.locator(for: workingCopyID)
        _ = try await privateWorkingCopyLocation.performWithAttestedPackage(for: workingCopyID) {
            try await services.createAndBindNewWork(
                locator,
                proposedDescriptor: descriptor,
                allowedEpisodeIDs: allowedEpisodes
            )
        }
        knownBoundLocators.insert(locator)
        signalContinuation.yield()
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
