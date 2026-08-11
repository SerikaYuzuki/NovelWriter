#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

extension DeviceSyncProductionRuntimeBox {
    func fetchSnapshot(for key: EpisodeSyncKey) async throws -> EpisodeRemoteSnapshot {
        try await readyServices().transport.fetchSnapshot(for: key)
    }

    func fetchRevision(_ id: SyncRevisionID, for key: EpisodeSyncKey) async throws -> EpisodeRevision {
        try await readyServices().transport.fetchRevision(id, for: key)
    }

    func claimLease(_ request: EpisodeLeaseClaimRequest) async throws -> EpisodeLeaseClaimResult {
        try await readyServices().transport.claimLease(request)
    }

    func releaseLease(
        key: EpisodeSyncKey,
        expectedAuthority: EpisodeLeaseAuthority
    ) async throws -> EpisodeRemoteSnapshot {
        try await readyServices().transport.releaseLease(
            key: key,
            expectedAuthority: expectedAuthority
        )
    }

    func publish(_ request: EpisodePublishRequest) async throws -> EpisodePublishResult {
        try await readyServices().transport.publish(request)
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await readyServices().workTransport.fetchSnapshot(for: workID)
    }

    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision {
        try await readyServices().workTransport.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        try await readyServices().workTransport.publish(request)
    }

    func readyServices() throws -> AppleDeviceSyncServices {
        guard case let .ready(services) = state else { throw EpisodeSyncTransportError.unavailable }
        return services
    }

    static func localOnlyResolution(
        from resolved: AppleLocalResolvedWorkingCopy?,
        remoteAvailability: DeviceSyncRemoteAvailability
    ) -> DeviceSyncBindingResolution? {
        guard let resolved else { return nil }
        return DeviceSyncBindingResolution(
            binding: resolved.binding,
            descriptor: nil,
            journal: resolved.journal,
            workJournal: resolved.workJournal,
            allowedEpisodeIDs: resolved.allowedEpisodeIDs,
            remoteAvailability: remoteAvailability
        )
    }

    static func remoteAvailability(for error: any Error) -> DeviceSyncRemoteAvailability {
        if let transportError = error as? EpisodeSyncTransportError,
           transportError == .unavailable {
            return .temporarilyOffline
        }
        if let servicesError = error as? AppleDeviceSyncServicesError,
           servicesError == .blocked(.temporarilyUnavailable) {
            return .temporarilyOffline
        }
        guard let adapterError = error as? CloudKitSyncAdapterError else {
            return .configurationBlocked
        }
        switch adapterError {
        case .temporarilyUnavailable, .accountUnavailable(.temporarilyUnavailable):
            return .temporarilyOffline
        case let .partialFailure(kinds)
            where !kinds.isEmpty && kinds.allSatisfy { $0 == .temporarilyUnavailable }:
            return .temporarilyOffline
        default:
            return .configurationBlocked
        }
    }

    static func remoteAvailability(
        for blocked: AppleDeviceSyncBlockedServices?
    ) -> DeviceSyncRemoteAvailability {
        guard let blocked,
              blocked.availability == .blocked(.temporarilyUnavailable) else {
            return .configurationBlocked
        }
        return .temporarilyOffline
    }

    func retryRemoteBootstrapIfNeeded() async {
        guard case let .blocked(blocked?) = state,
              blocked.availability == .blocked(.temporarilyUnavailable),
              let bootstrapContainerIdentifier else { return }
        await bootstrap(containerIdentifier: bootstrapContainerIdentifier)
    }

    static func permitsLocalResolutionFallback(for error: any Error) -> Bool {
        if error is AppleDeviceSyncServicesError {
            return true
        }
        if let transportError = error as? EpisodeSyncTransportError,
           transportError == .unavailable {
            return true
        }
        // Remote catalog/work/schema failures must not disable package→journal.
        // descriptor=nil keeps every later network operation fenced in App code.
        return error is CloudKitSyncAdapterError
    }

    func observeSignals(from services: AppleDeviceSyncServices) {
        signalTask?.cancel()
        signalTask = Task { [weak self] in
            for await _ in services.signals {
                try? await services.refreshTrackedChanges()
                await self?.yieldSignal()
            }
        }
    }

    func yieldSignal() {
        signalContinuation.yield()
    }

    static func locator(for session: DocumentSessionToken) throws -> AppleLocalDocumentLocator {
        let path = session.documentURL.standardizedFileURL.path
        let input = "FUMINIWA-APPLE-LOCAL-DOCUMENT-LOCATOR-V1\nmacos-file-url\n"
            + "\(path.utf8.count):\(path)"
        return try AppleLocalDocumentLocator(
            rawValue: "v1:" + SyncContentDigest(content: input).rawValue
        )
    }

    func bootstrap(containerIdentifier: String) async {
        bootstrapContainerIdentifier = containerIdentifier
        // A missing production entitlement blocks only the remote transport.
        // Keep the already-prepared local metadata, binding, journal, and WAL
        // available so D-060 editing never depends on CKContainer construction.
        guard AppleDeviceSyncEntitlementProbe.hasCloudKitContainer(containerIdentifier) else {
            state = .blocked(nil)
            signalContinuation.yield()
            return
        }
        state = .starting
        do {
            let result = try await localBootstrap.bootstrap(containerIdentifier: containerIdentifier)
            switch result {
            case let .ready(services):
                state = .ready(services)
                observeSignals(from: services)
            case let .blocked(blocked):
                state = .blocked(blocked)
            }
        } catch {
            state = .blocked(nil)
        }
        signalContinuation.yield()
    }
}

#endif
