#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
import Darwin
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

private enum DeviceSyncProductionCompositionError: Error {
    case missingCloudKitEntitlement
}

final class DeviceSyncProductionComposition: @unchecked Sendable {
    static let containerIdentifier = "iCloud.dev.serikayuzuki.fuminiwa.sync"

    let runtime: DeviceSyncRuntime
    private let runtimeBox: DeviceSyncProductionRuntimeBox

    init(fileManager: FileManager = .default) throws {
        guard AppleDeviceSyncEntitlementProbe.hasCloudKitContainer(Self.containerIdentifier) else {
            throw DeviceSyncProductionCompositionError.missingCloudKitEntitlement
        }
        let supportRoot = try Self.supportRoot(fileManager: fileManager)
        let workingCopyRoot = try DeviceSyncPrivateWorkingCopyRoot.prepare(
            supportRoot.deletingLastPathComponent()
                .appendingPathComponent("SyncWorkingCopies-v1", isDirectory: true),
            fileManager: fileManager
        )
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: supportRoot)
        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let runtimeBox = DeviceSyncProductionRuntimeBox(
            localBootstrap: localBootstrap,
            workingCopyRoot: workingCopyRoot,
            signalContinuation: streamPair.continuation
        )
        self.runtimeBox = runtimeBox
        let recoveryStore = try FileDeviceSyncMergeRecoveryStore(
            rootURL: supportRoot.appendingPathComponent("merge-recovery-v1", isDirectory: true)
        )
        runtime = DeviceSyncRuntime(
            replicaID: localBootstrap.replicaID,
            transport: runtimeBox,
            binding: { session, _ in
                try await runtimeBox.resolve(
                    session: session,
                    localSourceDocumentID: session.documentID
                )
            },
            remoteChangeSignals: streamPair.stream,
            mergeRecoveryStore: recoveryStore,
            setup: DeviceSyncSetupRuntime(
                privateWorkingCopyDestination: { session in
                    try workingCopyRoot.destination(for: session)
                },
                validatePrivateWorkingCopy: { url in
                    try workingCopyRoot.validateCopiedPackage(at: url)
                },
                candidates: { session, sourceDocumentID, digest in
                    try await runtimeBox.candidates(
                        session: session,
                        sourceDocumentID: sourceDocumentID,
                        digest: digest
                    )
                },
                startNew: { session, descriptor, allowedEpisodes in
                    try await runtimeBox.startNew(
                        session: session,
                        descriptor: descriptor,
                        allowedEpisodes: allowedEpisodes
                    )
                },
                bindExisting: { session, sourceDocumentID, digest, workID, allowedEpisodes in
                    try await runtimeBox.bind(
                        session: session,
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

private actor DeviceSyncProductionRuntimeBox: EpisodeSyncTransport {
    private enum State {
        case starting
        case ready(AppleDeviceSyncServices)
        case blocked(AppleDeviceSyncBlockedServices?)
    }

    private let localBootstrap: AppleDeviceSyncLocalBootstrap
    private let workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot
    private let signalContinuation: AsyncStream<Void>.Continuation
    private var state: State = .starting
    private var signalTask: Task<Void, Never>?
    private var knownBoundLocators: Set<AppleLocalDocumentLocator> = []

    init(
        localBootstrap: AppleDeviceSyncLocalBootstrap,
        workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot,
        signalContinuation: AsyncStream<Void>.Continuation
    ) {
        self.localBootstrap = localBootstrap
        self.workingCopyRoot = workingCopyRoot
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
        session: DocumentSessionToken,
        localSourceDocumentID: UUID
    ) async throws -> DeviceSyncBindingResolution? {
        let locator = try Self.locator(for: session)
        guard try workingCopyRoot.isEligible(session) else {
            switch localBootstrap.localStatus(for: locator) {
            case .unbound:
                return nil
            case .bound, .boundAndBlocked:
                throw EpisodeSyncTransportError.unavailable
            }
        }
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
            guard try workingCopyRoot.isEligible(session) else {
                throw EpisodeSyncTransportError.unavailable
            }
            return DeviceSyncBindingResolution(
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
        session: DocumentSessionToken,
        sourceDocumentID: UUID,
        digest: SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor] {
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        _ = try Self.locator(for: session)
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
        let locator = try Self.locator(for: session)
        let services = try readyServices()
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        try await services.bootstrapZoneForNewSync()
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        try await services.createWork(descriptor)
        guard try workingCopyRoot.isEligible(session) else {
            throw EpisodeSyncTransportError.unavailable
        }
        _ = try await services.bind(
            locator,
            to: descriptor.workID,
            localSourceDocumentID: descriptor.sourceDocumentID,
            allowedEpisodeIDs: allowedEpisodes,
            matching: descriptor.structureDigest
        )
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
        let locator = try Self.locator(for: session)
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
    ) throws -> DeviceSyncBindingResolution? {
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

    private static func locator(for session: DocumentSessionToken) throws -> AppleLocalDocumentLocator {
        let path = session.documentURL.standardizedFileURL.path
        let input = "FUMINIWA-APPLE-LOCAL-DOCUMENT-LOCATOR-V1\nmacos-file-url\n"
            + "\(path.utf8.count):\(path)"
        return try AppleLocalDocumentLocator(
            rawValue: "v1:" + SyncContentDigest(content: input).rawValue
        )
    }
}

struct DeviceSyncPrivateWorkingCopyRoot: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let url: URL
    let identity: Identity

    static func prepare(_ requestedURL: URL, fileManager: FileManager) throws -> Self {
        let requested = requestedURL.standardizedFileURL
        guard requested.isFileURL, requested.path != "/" else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateNoSymlinkComponents(requested)
        try fileManager.createDirectory(at: requested, withIntermediateDirectories: true)
        try validateNoSymlinkComponents(requested)
        let root = requested.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == requested.path,
              let status = try pathStatus(root),
              status.st_mode & S_IFMT == S_IFDIR else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        return Self(
            url: root,
            identity: Identity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        )
    }

    func destination(for session: DocumentSessionToken) throws -> URL? {
        try validateFixedRoot()
        guard try isEligible(session) == false else { return nil }
        try validateFixedRoot()
        return url.appendingPathComponent("\(UUID().uuidString).novelpkg", isDirectory: true)
    }

    func isEligible(_ session: DocumentSessionToken) throws -> Bool {
        try validateFixedRoot()
        let requested = session.documentURL.standardizedFileURL
        guard requested.isFileURL,
              requested.path != url.path,
              requested.path.hasPrefix(url.path + "/"),
              requested.deletingLastPathComponent().path == url.path else { return false }
        try validateCopiedPackage(at: requested)
        return true
    }

    func validateCopiedPackage(at packageURL: URL) throws {
        try validateFixedRoot()
        let requested = packageURL.standardizedFileURL
        guard requested.isFileURL,
              requested.path != url.path,
              requested.deletingLastPathComponent().path == url.path else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try Self.validateNoSymlinkComponents(requested)
        guard let initial = try Self.pathStatus(requested),
              initial.st_mode & S_IFMT == S_IFDIR else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == requested.path,
              resolved.path.hasPrefix(url.path + "/") else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateFixedRoot()
        guard let final = try Self.pathStatus(requested),
              final.st_mode & S_IFMT == S_IFDIR,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
    }

    func validateFixedRoot() throws {
        try Self.validateNoSymlinkComponents(url)
        guard let status = try Self.pathStatus(url),
              status.st_mode & S_IFMT == S_IFDIR,
              UInt64(status.st_dev) == identity.device,
              UInt64(status.st_ino) == identity.inode else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
    }

    private static func validateNoSymlinkComponents(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard let status = try pathStatus(current) else { return }
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw AppleDeviceSyncServicesError.unsafeRoot
            }
        }
    }

    private static func pathStatus(_ url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status
        }
        guard errno == ENOENT else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        return nil
    }
}
#endif
