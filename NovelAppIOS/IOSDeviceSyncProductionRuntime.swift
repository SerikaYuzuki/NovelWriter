#if canImport(NovelSyncCloudKit)
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

final class IOSDeviceSyncProductionComposition: @unchecked Sendable {
    static let containerIdentifier = "iCloud.dev.serikayuzuki.fuminiwa.sync"

    let runtime: IOSDeviceSyncRuntime
    private let runtimeBox: IOSDeviceSyncProductionRuntimeBox

    init(fileManager: FileManager = .default) throws {
        let supportRoot = try Self.supportRoot(fileManager: fileManager)
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: supportRoot)
        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let runtimeBox = IOSDeviceSyncProductionRuntimeBox(
            localBootstrap: localBootstrap,
            signalContinuation: streamPair.continuation
        )
        self.runtimeBox = runtimeBox
        runtime = IOSDeviceSyncRuntime(
            replicaID: localBootstrap.replicaID,
            transport: runtimeBox,
            binding: { workingCopyID, sourceDocumentID, _ in
                try await runtimeBox.resolve(
                    workingCopyID: workingCopyID,
                    localSourceDocumentID: sourceDocumentID
                )
            },
            remoteChangeSignals: streamPair.stream,
            mergeRecoveryStore: try IOSFileDeviceSyncMergeRecoveryStore(
                rootURL: supportRoot.appendingPathComponent("merge-recovery-v1", isDirectory: true)
            ),
            setup: IOSDeviceSyncSetupRuntime(
                candidates: { workingCopyID, sourceDocumentID, digest in
                    try await runtimeBox.candidates(
                        workingCopyID: workingCopyID,
                        sourceDocumentID: sourceDocumentID,
                        digest: digest
                    )
                },
                startNew: { workingCopyID, descriptor, allowedEpisodes in
                    try await runtimeBox.startNew(
                        workingCopyID: workingCopyID,
                        descriptor: descriptor,
                        allowedEpisodes: allowedEpisodes
                    )
                },
                bindExisting: { workingCopyID, sourceDocumentID, digest, workID, allowedEpisodes in
                    try await runtimeBox.bind(
                        workingCopyID: workingCopyID,
                        sourceDocumentID: sourceDocumentID,
                        digest: digest,
                        workID: workID,
                        allowedEpisodes: allowedEpisodes
                    )
                }
            )
        )
    }

    func bootstrap() async {
        await runtimeBox.bootstrap(containerIdentifier: Self.containerIdentifier)
    }

    private static func supportRoot(fileManager: FileManager) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        return applicationSupport
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("DeviceSync-v1", isDirectory: true)
    }
}

private actor IOSDeviceSyncProductionRuntimeBox: EpisodeSyncTransport {
    private enum State {
        case starting
        case ready(AppleDeviceSyncServices)
        case blocked(AppleDeviceSyncBlockedServices?)
    }

    private let localBootstrap: AppleDeviceSyncLocalBootstrap
    private let signalContinuation: AsyncStream<Void>.Continuation
    private var state: State = .starting
    private var signalTask: Task<Void, Never>?
    private var knownBoundLocators: Set<AppleLocalDocumentLocator> = []

    init(
        localBootstrap: AppleDeviceSyncLocalBootstrap,
        signalContinuation: AsyncStream<Void>.Continuation
    ) {
        self.localBootstrap = localBootstrap
        self.signalContinuation = signalContinuation
    }

    deinit {
        signalTask?.cancel()
        signalContinuation.finish()
    }

    func bootstrap(containerIdentifier: String) async {
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

    func resolve(
        workingCopyID: IOSPrivateDocumentID,
        localSourceDocumentID: UUID
    ) async throws -> IOSDeviceSyncBindingResolution? {
        let locator = try Self.locator(for: workingCopyID)
        let locallyBound = knownBoundLocators.contains(locator) || {
            switch localBootstrap.localStatus(for: locator) {
            case .unbound:
                return false
            case .bound, .boundAndBlocked:
                return true
            }
        }()
        guard locallyBound else { return nil }
        knownBoundLocators.insert(locator)
        switch state {
        case let .ready(services):
            guard let resolved = try await services.resolve(
                locator,
                localSourceDocumentID: localSourceDocumentID
            ) else { return nil }
            return IOSDeviceSyncBindingResolution(
                binding: resolved.binding,
                descriptor: resolved.descriptor,
                journal: resolved.journal,
                allowedEpisodeIDs: resolved.allowedEpisodeIDs
            )
        case .starting:
            return try localOnlyResolution(for: localBootstrap.localStatus(for: locator))
        case let .blocked(blocked):
            let status = if let blocked {
                await blocked.localStatus(for: locator)
            } else {
                localBootstrap.localStatus(for: locator)
            }
            return try localOnlyResolution(for: status)
        }
    }

    func candidates(
        workingCopyID: IOSPrivateDocumentID,
        sourceDocumentID: UUID,
        digest: SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor] {
        _ = try Self.locator(for: workingCopyID)
        return try await readyServices().workCandidates(
            sourceDocumentIDHint: sourceDocumentID,
            matching: digest
        )
    }

    func startNew(
        workingCopyID: IOSPrivateDocumentID,
        descriptor: SyncWorkDescriptor,
        allowedEpisodes: [EpisodeID]
    ) async throws {
        let services = try readyServices()
        try await services.bootstrapZoneForNewSync()
        try await services.createWork(descriptor)
        _ = try await services.bind(
            Self.locator(for: workingCopyID),
            to: descriptor.workID,
            localSourceDocumentID: descriptor.sourceDocumentID,
            allowedEpisodeIDs: allowedEpisodes,
            matching: descriptor.structureDigest
        )
        knownBoundLocators.insert(try Self.locator(for: workingCopyID))
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
        _ = try await readyServices().bind(
            locator,
            to: workID,
            localSourceDocumentID: sourceDocumentID,
            allowedEpisodeIDs: allowedEpisodes,
            matching: digest
        )
        knownBoundLocators.insert(locator)
        signalContinuation.yield()
    }

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

    private func readyServices() throws -> AppleDeviceSyncServices {
        guard case let .ready(services) = state else { throw EpisodeSyncTransportError.unavailable }
        return services
    }

    private func localOnlyResolution(
        for status: AppleDeviceSyncLocalBindingStatus
    ) throws -> IOSDeviceSyncBindingResolution? {
        switch status {
        case .unbound:
            nil
        case .bound, .boundAndBlocked:
            throw EpisodeSyncTransportError.unavailable
        }
    }

    private func observeSignals(from services: AppleDeviceSyncServices) {
        signalTask?.cancel()
        signalTask = Task { [weak self] in
            for await _ in services.signals {
                try? await services.refreshTrackedChanges()
                await self?.yieldSignal()
            }
        }
    }

    private func yieldSignal() {
        signalContinuation.yield()
    }

    private static func locator(for workingCopyID: IOSPrivateDocumentID) throws -> AppleLocalDocumentLocator {
        let packageName = workingCopyID.packageName
        let input = "FUMINIWA-APPLE-LOCAL-DOCUMENT-LOCATOR-V1\nios-private-package\n"
            + "\(packageName.utf8.count):\(packageName)"
        return try AppleLocalDocumentLocator(
            rawValue: "v1:" + SyncContentDigest(content: input).rawValue
        )
    }
}
#endif
