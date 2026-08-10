import Foundation
import NovelCore
import NovelSync

public enum AppleDeviceSyncSignal: Equatable, Sendable {
    case remoteChangesAvailable
    case accountChanged(AppleDeviceSyncAvailability)
    case zoneReset
    case statePersistenceFailed
}

public enum AppleDeviceSyncLocalBindingStatus: Equatable, Sendable {
    case unbound
    case bound
    case boundAndBlocked(AppleDeviceSyncBlockReason)
}

/// accountを確認できない起動でも、旧remote identityやjournalを公開せず、
/// 「このlocal copyは同期済みだったか」だけをAppへ返す。
public final class AppleDeviceSyncBlockedServices: @unchecked Sendable {
    public let replicaID: SyncReplicaID
    public let availability: AppleDeviceSyncAvailability

    private let metadataStore: AppleDeviceSyncMetadataStore
    private let reason: AppleDeviceSyncBlockReason

    init(
        replicaID: SyncReplicaID,
        reason: AppleDeviceSyncBlockReason,
        metadataStore: AppleDeviceSyncMetadataStore
    ) {
        self.replicaID = replicaID
        availability = .blocked(reason)
        self.reason = reason
        self.metadataStore = metadataStore
    }

    public func localStatus(
        for locator: AppleLocalDocumentLocator
    ) async -> AppleDeviceSyncLocalBindingStatus {
        if await metadataStore.binding(for: locator) == nil {
            return .unbound
        }
        return .boundAndBlocked(reason)
    }
}

public enum AppleDeviceSyncBootstrapResult: Sendable {
    case ready(AppleDeviceSyncServices)
    case blocked(AppleDeviceSyncBlockedServices)
}

public struct AppleResolvedWorkingCopy: Sendable {
    public let binding: SyncWorkingCopyBinding
    public let descriptor: SyncWorkDescriptor
    public let allowedEpisodeIDs: Set<EpisodeID>
    public let journal: any EpisodeSyncJournal

    public func allowsEpisode(_ episodeID: EpisodeID) -> Bool {
        allowedEpisodeIDs.contains(episodeID)
    }
}

private actor AppleDeviceSyncSignalRelay {
    private let accountGate: AppleDeviceSyncAccountGate
    private let metadataStore: AppleDeviceSyncMetadataStore
    private let engineStateGeneration: UInt64
    private let continuation: AsyncStream<AppleDeviceSyncSignal>.Continuation

    init(
        accountGate: AppleDeviceSyncAccountGate,
        metadataStore: AppleDeviceSyncMetadataStore,
        engineStateGeneration: UInt64,
        continuation: AsyncStream<AppleDeviceSyncSignal>.Continuation
    ) {
        self.accountGate = accountGate
        self.metadataStore = metadataStore
        self.engineStateGeneration = engineStateGeneration
        self.continuation = continuation
    }

    func handle(_ signal: CloudKitSyncSignal) async {
        switch signal {
        case .remoteChangesAvailable:
            continuation.yield(.remoteChangesAvailable)
        case .accountChanged:
            let availability = await accountGate.observeAccountChange()
            if case .blocked = availability {
                do {
                    _ = try await metadataStore.invalidateEngineState(
                        expectedGeneration: engineStateGeneration
                    )
                } catch {
                    continuation.yield(.statePersistenceFailed)
                }
            }
            continuation.yield(.accountChanged(availability))
        case .zoneReset:
            continuation.yield(.zoneReset)
        case .stateSerializationFailed:
            continuation.yield(.statePersistenceFailed)
        }
    }

    func statePersistenceFailed() {
        continuation.yield(.statePersistenceFailed)
    }
}

/// Apple版Device Syncのcomposition root。CloudKit型をAppへ出さず、remote、journal、
/// install-stable replica、明示binding、content-free signalを一つに束ねる。
public final class AppleDeviceSyncServices: @unchecked Sendable {
    private static let journalDirectoryName = "journals-v1"
    private static let assetDirectoryName = "cloud-assets-v1"

    public let replicaID: SyncReplicaID
    public let transport: any EpisodeSyncTransport
    public let signals: AsyncStream<AppleDeviceSyncSignal>

    private let cloudTransport: CloudKitEpisodeSyncTransport
    private let remoteBoundary: AppleDeviceSyncRemoteBoundary
    private let metadataStore: AppleDeviceSyncMetadataStore
    private let accountGate: AppleDeviceSyncAccountGate
    private let journalFactory: AppleDeviceSyncJournalFactory
    private let signalContinuation: AsyncStream<AppleDeviceSyncSignal>.Continuation

    private init(
        replicaID: SyncReplicaID,
        cloudTransport: CloudKitEpisodeSyncTransport,
        remoteBoundary: AppleDeviceSyncRemoteBoundary,
        journalFactory: AppleDeviceSyncJournalFactory,
        metadataStore: AppleDeviceSyncMetadataStore,
        accountGate: AppleDeviceSyncAccountGate,
        signals: AsyncStream<AppleDeviceSyncSignal>,
        signalContinuation: AsyncStream<AppleDeviceSyncSignal>.Continuation
    ) {
        self.replicaID = replicaID
        self.cloudTransport = cloudTransport
        self.remoteBoundary = remoteBoundary
        transport = remoteBoundary
        self.metadataStore = metadataStore
        self.accountGate = accountGate
        self.journalFactory = journalFactory
        self.signals = signals
        self.signalContinuation = signalContinuation
    }

    deinit {
        signalContinuation.finish()
    }

    public static func make(
        containerIdentifier: String,
        rootURL: URL
    ) async throws -> AppleDeviceSyncServices {
        switch try await bootstrap(
            containerIdentifier: containerIdentifier,
            rootURL: rootURL
        ) {
        case let .ready(services):
            return services
        case let .blocked(blocked):
            guard case let .blocked(reason) = blocked.availability else {
                throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
            }
            throw AppleDeviceSyncServicesError.blocked(reason)
        }
    }

    /// fresh launchで最初に使う入口。account確認不能／相違時もlocal bindingの有無だけは
    /// 返し、同期済みcopyをnil-runtimeの編集可能状態へ誤って落とさない。
    public static func bootstrap(
        containerIdentifier: String,
        rootURL: URL
    ) async throws -> AppleDeviceSyncBootstrapResult {
        let metadataStore = try AppleDeviceSyncMetadataStore(rootURL: rootURL)
        let localMetadata = await metadataStore.snapshot()
        let accountScope: AppleCloudAccountScope
        do {
            accountScope = try await AppleCloudAccountScopeResolver.resolve(
                containerIdentifier: containerIdentifier
            )
        } catch let error as CloudKitSyncAdapterError {
            if case .invalidConfiguration = error {
                throw error
            }
            // identityを確証できないCloudKit failureでは、既存bindingをlocal-onlyへ
            // 誤降格させずblocked bootstrapを返す。
            return .blocked(
                AppleDeviceSyncBlockedServices(
                    replicaID: localMetadata.replicaID,
                    reason: .accountUnavailable,
                    metadataStore: metadataStore
                )
            )
        }
        let metadata: AppleDeviceSyncMetadataSnapshot
        do {
            metadata = try await metadataStore.installAccountScope(accountScope)
        } catch let AppleDeviceSyncServicesError.blocked(reason) {
            return .blocked(
                AppleDeviceSyncBlockedServices(
                    replicaID: localMetadata.replicaID,
                    reason: reason,
                    metadataStore: metadataStore
                )
            )
        }
        let services = try await makeReadyServices(
            containerIdentifier: containerIdentifier,
            metadataStore: metadataStore,
            metadata: metadata,
            accountScope: accountScope
        )
        return .ready(services)
    }

    private static func makeReadyServices(
        containerIdentifier: String,
        metadataStore: AppleDeviceSyncMetadataStore,
        metadata: AppleDeviceSyncMetadataSnapshot,
        accountScope: AppleCloudAccountScope
    ) async throws -> AppleDeviceSyncServices {
        let safeRoot = await metadataStore.safeRootURL()
        let accountGate = AppleDeviceSyncAccountGate(
            expectedScope: accountScope,
            scopeResolver: {
                try await AppleCloudAccountScopeResolver.resolve(
                    containerIdentifier: containerIdentifier
                )
            }
        )
        let streamPair = AsyncStream<AppleDeviceSyncSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let relay = AppleDeviceSyncSignalRelay(
            accountGate: accountGate,
            metadataStore: metadataStore,
            engineStateGeneration: metadata.engineStateGeneration,
            continuation: streamPair.continuation
        )
        let assetRoot = safeRoot.appendingPathComponent(assetDirectoryName, isDirectory: true)
        let cloudTransport = try CloudKitEpisodeSyncTransport(
            containerIdentifier: containerIdentifier,
            assetRootURL: assetRoot,
            restoredEngineState: metadata.engineState,
            stateSerializationHandler: { state in
                do {
                    // falseはaccount invalidation後に届いた旧generation callback。
                    // errorではなく意図どおり無視し、新accountへstateを持ち越さない。
                    _ = try await metadataStore.saveEngineState(
                        state,
                        generation: metadata.engineStateGeneration
                    )
                } catch {
                    await relay.statePersistenceFailed()
                }
            },
            signalHandler: { signal in
                await relay.handle(signal)
            }
        )
        let journalRoot = safeRoot.appendingPathComponent(journalDirectoryName, isDirectory: true)
        let remoteBoundary = AppleDeviceSyncRemoteBoundary(
            transport: cloudTransport,
            accountGate: accountGate
        )
        let journalFactory = AppleDeviceSyncJournalFactory(
            rootURL: journalRoot,
            accountGate: accountGate,
            metadataStore: metadataStore
        )
        return AppleDeviceSyncServices(
            replicaID: metadata.replicaID,
            cloudTransport: cloudTransport,
            remoteBoundary: remoteBoundary,
            journalFactory: journalFactory,
            metadataStore: metadataStore,
            accountGate: accountGate,
            signals: streamPair.stream,
            signalContinuation: streamPair.continuation
        )
    }

    public func availability() async -> AppleDeviceSyncAvailability {
        await accountGate.availability()
    }

    /// 新規sync libraryを利用者が明示開始した場合だけzoneを作成する。
    public func bootstrapZoneForNewSync() async throws {
        try await accountGate.requireAvailable()
        try await cloudTransport.bootstrapZoneForNewSync()
    }

    public func createWork(_ descriptor: SyncWorkDescriptor) async throws {
        try await remoteBoundary.createWork(descriptor)
    }

    public func listWorks() async throws -> [SyncWorkDescriptor] {
        try await remoteBoundary.listWorks()
    }

    /// structure一致だけを候補条件とし、sourceDocumentID一致は表示順hintに限る。
    /// この呼出しはbindingを一切変更しない。
    public func workCandidates(
        sourceDocumentIDHint: UUID,
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor] {
        let works = try await listWorks()
        return AppleDeviceSyncWorkMatcher.candidates(
            from: works,
            sourceDocumentIDHint: sourceDocumentIDHint,
            structureDigest: structureDigest
        )
    }

    public func localStatus(
        for locator: AppleLocalDocumentLocator
    ) async -> AppleDeviceSyncLocalBindingStatus {
        guard await metadataStore.binding(for: locator) != nil else {
            return .unbound
        }
        switch await accountGate.availability() {
        case .ready:
            return .bound
        case let .blocked(reason):
            return .boundAndBlocked(reason)
        }
    }

    /// bindingだけをAppへ渡さず、account/work/source continuity確認と
    /// binding時のepisode allowlist、copy専用journalを一つの境界で組み立てる。
    public func resolve(
        _ locator: AppleLocalDocumentLocator,
        localSourceDocumentID: UUID
    ) async throws -> AppleResolvedWorkingCopy? {
        try await accountGate.requireAvailable()
        guard let localBinding = await metadataStore.bindingSnapshot(for: locator) else {
            return nil
        }
        let works = try await remoteBoundary.listWorks()
        let descriptor = try AppleDeviceSyncWorkMatcher.requireBoundDescriptor(
            workID: localBinding.binding.workID,
            localSourceDocumentID: localSourceDocumentID,
            in: works
        )
        let journal = try await journalFactory.journal(for: localBinding.binding)
        return AppleResolvedWorkingCopy(
            binding: localBinding.binding,
            descriptor: descriptor,
            allowedEpisodeIDs: localBinding.allowedEpisodeIDs,
            journal: journal
        )
    }

    @discardableResult
    public func bind(
        _ locator: AppleLocalDocumentLocator,
        to workID: SyncWorkID,
        localSourceDocumentID: UUID,
        allowedEpisodeIDs: [EpisodeID],
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> AppleResolvedWorkingCopy {
        let descriptor = try await requireRemoteWork(workID, matching: structureDigest)
        try AppleDeviceSyncWorkMatcher.requireSourceContinuity(
            descriptor,
            localSourceDocumentID: localSourceDocumentID
        )
        _ = try await metadataStore.bind(
            locator,
            to: workID,
            allowedEpisodeIDs: allowedEpisodeIDs
        )
        guard let resolved = try await resolve(
            locator,
            localSourceDocumentID: localSourceDocumentID
        ) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        return resolved
    }

    /// 通常bindは既存locatorの行先を変えない。明示的な付け替えだけをこのAPIへ通す。
    @discardableResult
    public func rebind(
        _ locator: AppleLocalDocumentLocator,
        to workID: SyncWorkID,
        localSourceDocumentID: UUID,
        allowedEpisodeIDs: [EpisodeID],
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> AppleResolvedWorkingCopy {
        let descriptor = try await requireRemoteWork(workID, matching: structureDigest)
        try AppleDeviceSyncWorkMatcher.requireSourceContinuity(
            descriptor,
            localSourceDocumentID: localSourceDocumentID
        )
        _ = try await metadataStore.rebind(
            locator,
            to: workID,
            allowedEpisodeIDs: allowedEpisodeIDs
        )
        guard let resolved = try await resolve(
            locator,
            localSourceDocumentID: localSourceDocumentID
        ) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        return resolved
    }

    @discardableResult
    public func unbind(
        _ locator: AppleLocalDocumentLocator
    ) async throws -> Bool {
        try await accountGate.requireAvailable()
        return try await metadataStore.unbind(locator) != nil
    }

    public func refreshTrackedChanges() async throws {
        try await accountGate.requireAvailable()
        try await cloudTransport.refreshTrackedChanges()
    }

    public func cancelTrackedChanges() async {
        await cloudTransport.cancelTrackedChanges()
    }

    private func requireRemoteWork(
        _ workID: SyncWorkID,
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> SyncWorkDescriptor {
        let works = try await remoteBoundary.listWorks()
        return try AppleDeviceSyncWorkMatcher.requireDescriptor(
            workID: workID,
            structureDigest: structureDigest,
            in: works
        )
    }
}

enum AppleDeviceSyncWorkMatcher {
    static func candidates(
        from works: [SyncWorkDescriptor],
        sourceDocumentIDHint: UUID,
        structureDigest: SyncWorkStructureDigest
    ) -> [SyncWorkDescriptor] {
        works
            .filter { $0.structureDigest == structureDigest }
            .sorted { lhs, rhs in
                let lhsMatchesHint = lhs.sourceDocumentID == sourceDocumentIDHint
                let rhsMatchesHint = rhs.sourceDocumentID == sourceDocumentIDHint
                if lhsMatchesHint != rhsMatchesHint {
                    return lhsMatchesHint
                }
                return lhs.workID.rawValue.uuidString < rhs.workID.rawValue.uuidString
            }
    }

    static func requireDescriptor(
        workID: SyncWorkID,
        structureDigest: SyncWorkStructureDigest,
        in works: [SyncWorkDescriptor]
    ) throws -> SyncWorkDescriptor {
        guard let descriptor = works.first(where: { $0.workID == workID }) else {
            throw AppleDeviceSyncServicesError.remoteWorkNotFound
        }
        guard descriptor.structureDigest == structureDigest else {
            throw AppleDeviceSyncServicesError.structureMismatch
        }
        return descriptor
    }

    static func requireBoundDescriptor(
        workID: SyncWorkID,
        localSourceDocumentID: UUID,
        in works: [SyncWorkDescriptor]
    ) throws -> SyncWorkDescriptor {
        guard let descriptor = works.first(where: { $0.workID == workID }) else {
            throw AppleDeviceSyncServicesError.remoteWorkNotFound
        }
        try requireSourceContinuity(
            descriptor,
            localSourceDocumentID: localSourceDocumentID
        )
        return descriptor
    }

    static func requireSourceContinuity(
        _ descriptor: SyncWorkDescriptor,
        localSourceDocumentID: UUID
    ) throws {
        guard descriptor.sourceDocumentID == localSourceDocumentID else {
            throw AppleDeviceSyncServicesError.sourceDocumentMismatch
        }
    }
}
