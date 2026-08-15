#if canImport(NovelSyncCloudKit)
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
    ) async throws -> AppleResolvedWorkingCopy? {
        if let existing = pendingCreateAndBindTasks[descriptor.workID] {
            return try await existing.value
        }
        let task = Task {
            try await self.performCreateAndBindNewWork(
                session: session,
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
        session: DocumentSessionToken,
        descriptor: SyncWorkDescriptor,
        allowedEpisodes: [EpisodeID]
    ) async throws -> AppleResolvedWorkingCopy? {
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        let locator = try locator(for: session)
        guard try locator == (AppleLocalDocumentLocator.cloudLibrary(workID: descriptor.workID)) else {
            throw EpisodeSyncTransportError.unavailable
        }
        // A process restart begins with an empty live cache. Seed this locator
        // from durable metadata without emitting a synthetic remote-change
        // signal; the startup/foreground refresh that called us is the retry.
        if isLocallyBound(locator) {
            knownBoundLocators.insert(locator)
        }
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        let remotelyResolved: AppleResolvedWorkingCopy?
        do {
            switch state {
            case let .ready(services):
                CloudKitSyncDiagnostic.log("cloud-library startNew ready")
                remotelyResolved = try await services.createAndBindNewWork(
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
                remotelyResolved = nil
            case .starting, .blocked(nil):
                CloudKitSyncDiagnostic.log("cloud-library startNew unavailable")
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
            recordCreationFailureLocalBinding(locator, status: liveStatus)
            CloudKitSyncDiagnostic.log("cloud-library startNew failed", error: error)
            throw error
        }
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        recordKnownLocalBinding(locator)
        return remotelyResolved
    }

    /// Library first-publish. `createWork` already wrote the Note work record.
    /// Remaining entities go through `NoteSyncCoordinator`; Work revision
    /// assets are not live-encoded.
    func resumeInitialWorkPublication(
        session: DocumentSessionToken,
        descriptor: SyncWorkDescriptor,
        allowedEpisodes: [EpisodeID],
        initialSnapshot: WorkSnapshot
    ) async throws {
        guard let resolved = try await startNew(
            session: session,
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

    /// A failed remote create can still leave the durable local intent and
    /// binding behind. Wake the app once when that fact is first discovered,
    /// but never let the retry failure emit another signal for the same work.
    @discardableResult
    func recordCreationFailureLocalBinding(
        _ locator: AppleLocalDocumentLocator,
        status: AppleDeviceSyncLocalBindingStatus
    ) -> Bool {
        guard status != .unbound else { return false }
        return recordKnownLocalBinding(locator)
    }

    /// Binding discovery is an edge-triggered wakeup. Both a successful resume
    /// and a failed create may discover the same durable binding, but neither
    /// may turn its own retry result into an unbounded signal loop.
    @discardableResult
    func recordKnownLocalBinding(_ locator: AppleLocalDocumentLocator) -> Bool {
        guard knownBoundLocators.insert(locator).inserted else { return false }
        signalContinuation.yield()
        return true
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
