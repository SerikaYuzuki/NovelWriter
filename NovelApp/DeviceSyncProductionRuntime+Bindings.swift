#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

extension DeviceSyncProductionRuntimeBox {
    func resolveLocalWork(
        session: DocumentSessionToken,
        localSourceDocumentID _: UUID
    ) async throws -> DeviceSyncBindingResolution? {
        let locator = try locator(for: session)
        guard try validateEligibility(session: session, locator: locator),
              isLocallyBound(locator),
              let local = try await localBootstrap.resolveLocal(locator) else { return nil }
        knownBoundLocators.insert(locator)
        return Self.localOnlyResolution(from: local, remoteAvailability: .temporarilyOffline)
    }

    func resolve(
        session: DocumentSessionToken,
        localSourceDocumentID: UUID
    ) async throws -> DeviceSyncBindingResolution? {
        let locator = try locator(for: session)
        guard try validateEligibility(session: session, locator: locator) else { return nil }
        guard isLocallyBound(locator) else { return nil }
        knownBoundLocators.insert(locator)
        await retryRemoteBootstrapIfNeeded()
        switch state {
        case let .ready(services):
            let resolution = try await resolveReady(
                services: services,
                locator: locator,
                localSourceDocumentID: localSourceDocumentID
            )
            guard try workingCopyRoot.isEligible(session) else {
                throw EpisodeSyncTransportError.unavailable
            }
            return resolution
        case .starting:
            let local = try await localBootstrap.resolveLocal(locator)
            return Self.localOnlyResolution(from: local, remoteAvailability: .temporarilyOffline)
        case let .blocked(blocked):
            let local = if let blocked {
                try await blocked.resolveLocal(locator)
            } else {
                try await localBootstrap.resolveLocal(locator)
            }
            return Self.localOnlyResolution(
                from: local,
                remoteAvailability: Self.remoteAvailability(for: blocked)
            )
        }
    }

    func validateEligibility(
        session: DocumentSessionToken,
        locator: AppleLocalDocumentLocator
    ) throws -> Bool {
        guard try workingCopyRoot.isEligible(session) else {
            switch localBootstrap.localStatus(for: locator) {
            case .unbound:
                return false
            case .bound, .boundAndBlocked:
                throw EpisodeSyncTransportError.unavailable
            }
        }
        return true
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

    func resolveReady(
        services: AppleDeviceSyncServices,
        locator: AppleLocalDocumentLocator,
        localSourceDocumentID: UUID
    ) async throws -> DeviceSyncBindingResolution? {
        do {
            guard let resolved = try await services.resolve(
                locator,
                localSourceDocumentID: localSourceDocumentID
            ) else { return nil }
            return DeviceSyncBindingResolution(
                binding: resolved.binding,
                descriptor: resolved.descriptor,
                journal: resolved.journal,
                workJournal: resolved.workJournal,
                allowedEpisodeIDs: resolved.allowedEpisodeIDs
            )
        } catch where Self.permitsLocalResolutionFallback(for: error) {
            return try await Self.localOnlyResolution(
                from: services.resolveLocal(locator),
                remoteAvailability: Self.remoteAvailability(for: error)
            )
        }
    }

    func candidates(
        session: DocumentSessionToken,
        sourceDocumentID: UUID,
        digest: SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor] {
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        _ = try locator(for: session)
        let candidates = try await readyServices().workCandidates(
            sourceDocumentIDHint: sourceDocumentID,
            matching: digest
        )
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        return candidates
    }

    func startNew(
        session: DocumentSessionToken,
        descriptor: SyncWorkDescriptor,
        allowedEpisodes: [EpisodeID]
    ) async throws {
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        let locator = try locator(for: session)
        guard try locator == (AppleLocalDocumentLocator.cloudLibrary(workID: descriptor.workID)) else {
            throw EpisodeSyncTransportError.unavailable
        }
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        do {
            switch state {
            case let .ready(services):
                _ = try await services.createAndBindNewWork(
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
            case .starting, .blocked(nil):
                throw EpisodeSyncTransportError.unavailable
            }
        } catch {
            // Domainはnetwork publishより先にpending creationとlocal bindingを
            // durable化する。remote失敗後も同一processでlocal preflightへ進めるよう、
            // live metadataを再照会してknown cacheを補正する。
            let liveStatus: AppleDeviceSyncLocalBindingStatus = switch state {
            case let .ready(services):
                await services.localStatus(for: locator)
            case let .blocked(blocked?):
                await blocked.localStatus(for: locator)
            case .starting, .blocked(nil):
                .unbound
            }
            if liveStatus != .unbound {
                knownBoundLocators.insert(locator)
                signalContinuation.yield()
            }
            throw error
        }
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        knownBoundLocators.insert(locator)
        signalContinuation.yield()
    }

    func bind(
        session: DocumentSessionToken,
        sourceDocumentID: UUID,
        digest: SyncWorkStructureDigest,
        workID: SyncWorkID,
        allowedEpisodes: [EpisodeID]
    ) async throws {
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        let services = try readyServices()
        let locator = try locator(for: session)
        guard try locator == (AppleLocalDocumentLocator.cloudLibrary(workID: workID)) else {
            throw EpisodeSyncTransportError.unavailable
        }
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        _ = try await services.bind(
            locator,
            to: workID,
            localSourceDocumentID: sourceDocumentID,
            allowedEpisodeIDs: allowedEpisodes,
            matching: digest
        )
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        knownBoundLocators.insert(locator)
        signalContinuation.yield()
    }
}

#endif
