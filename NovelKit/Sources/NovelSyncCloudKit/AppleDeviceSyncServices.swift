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
    private let journalFactory: AppleDeviceSyncJournalFactory
    private let reason: AppleDeviceSyncBlockReason

    init(
        replicaID: SyncReplicaID,
        reason: AppleDeviceSyncBlockReason,
        metadataStore: AppleDeviceSyncMetadataStore,
        journalFactory: AppleDeviceSyncJournalFactory
    ) {
        self.replicaID = replicaID
        availability = .blocked(reason)
        self.reason = reason
        self.metadataStore = metadataStore
        self.journalFactory = journalFactory
    }

    public func localStatus(
        for locator: AppleLocalDocumentLocator
    ) async -> AppleDeviceSyncLocalBindingStatus {
        if await metadataStore.containsBindingOrPendingWorkCreation(for: locator) == false {
            return .unbound
        }
        return .boundAndBlocked(reason)
    }

    public func resolveLocal(
        _ locator: AppleLocalDocumentLocator
    ) async throws -> AppleLocalResolvedWorkingCopy? {
        try await AppleLocalResolvedWorkingCopy.resolve(
            locator,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        )
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

/// Cloud accountやremote catalogを必要としない、端末内だけのbinding。
/// `workID`はjournal keyのportable identityとして使えるが、この値だけで
/// remote transportへ送信してよいことを意味しない。
public struct AppleLocalResolvedWorkingCopy: Sendable {
    public let binding: SyncWorkingCopyBinding
    public let allowedEpisodeIDs: Set<EpisodeID>
    public let journal: any EpisodeSyncJournal

    public func allowsEpisode(_ episodeID: EpisodeID) -> Bool {
        allowedEpisodeIDs.contains(episodeID)
    }

    static func resolve(
        _ locator: AppleLocalDocumentLocator,
        metadataStore: AppleDeviceSyncMetadataStore,
        journalFactory: AppleDeviceSyncJournalFactory
    ) async throws -> AppleLocalResolvedWorkingCopy? {
        guard let snapshot = await metadataStore.bindingSnapshot(for: locator) else {
            return nil
        }
        return try await AppleLocalResolvedWorkingCopy(
            binding: snapshot.binding,
            allowedEpisodeIDs: snapshot.allowedEpisodeIDs,
            journal: journalFactory.journal(for: snapshot.binding)
        )
    }
}

private actor AppleDeviceSyncSignalRelay {
    private let accountGate: AppleDeviceSyncAccountGate
    private let metadataStore: AppleDeviceSyncMetadataStore
    private var engineStateGeneration: UInt64
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
            let availability = await accountGate.blockForAccountChange()
            do {
                _ = try await metadataStore.invalidateEngineState(
                    expectedGeneration: engineStateGeneration
                )
            } catch {
                continuation.yield(.statePersistenceFailed)
            }
            continuation.yield(.accountChanged(availability))
        case .zoneReset:
            continuation.yield(.zoneReset)
        case .stateSerializationFailed:
            continuation.yield(.statePersistenceFailed)
        }
    }

    func updateEngineStateGeneration(_ generation: UInt64) {
        engineStateGeneration = generation
    }

    func persistEngineState(_ state: Data) async {
        do {
            // falseはaccount invalidation後に届いた旧generation callback。
            // errorではなく意図どおり無視し、新accountへstateを持ち越さない。
            _ = try await metadataStore.saveEngineState(
                state,
                generation: engineStateGeneration
            )
        } catch {
            continuation.yield(.statePersistenceFailed)
        }
    }
}

/// Apple版Device Syncのcomposition root。CloudKit型をAppへ出さず、remote、journal、
/// install-stable replica、明示binding、content-free signalを一つに束ねる。
public final class AppleDeviceSyncServices: @unchecked Sendable {
    static let journalDirectoryName = "journals-v1"
    private static let assetDirectoryName = "cloud-assets-v1"

    public let replicaID: SyncReplicaID
    public let transport: any EpisodeSyncTransport
    public let signals: AsyncStream<AppleDeviceSyncSignal>

    let cloudTransport: CloudKitEpisodeSyncTransport
    let remoteBoundary: AppleDeviceSyncRemoteBoundary
    let metadataStore: AppleDeviceSyncMetadataStore
    let accountGate: AppleDeviceSyncAccountGate
    let journalFactory: AppleDeviceSyncJournalFactory
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
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: rootURL)
        return try await localBootstrap.bootstrap(containerIdentifier: containerIdentifier)
    }

    static func bootstrapPrepared(
        containerIdentifier: String,
        metadataStore: AppleDeviceSyncMetadataStore,
        journalFactory: AppleDeviceSyncJournalFactory
    ) async throws -> AppleDeviceSyncBootstrapResult {
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
            return blockedResult(
                reason: .accountUnavailable,
                replicaID: localMetadata.replicaID,
                metadataStore: metadataStore,
                journalFactory: journalFactory
            )
        }
        let metadata: AppleDeviceSyncMetadataSnapshot
        do {
            metadata = try await metadataStore.installAccountScope(accountScope)
        } catch let AppleDeviceSyncServicesError.blocked(reason) {
            return blockedResult(
                reason: reason,
                replicaID: localMetadata.replicaID,
                metadataStore: metadataStore,
                journalFactory: journalFactory
            )
        }
        do {
            let services = try await makeReadyServices(
                containerIdentifier: containerIdentifier,
                metadataStore: metadataStore,
                metadata: metadata,
                accountScope: accountScope,
                journalFactory: journalFactory
            )
            return .ready(services)
        } catch let AppleDeviceSyncServicesError.blocked(reason) {
            return blockedResult(
                reason: reason,
                replicaID: localMetadata.replicaID,
                metadataStore: metadataStore,
                journalFactory: journalFactory
            )
        }
    }

    private static func blockedResult(
        reason: AppleDeviceSyncBlockReason,
        replicaID: SyncReplicaID,
        metadataStore: AppleDeviceSyncMetadataStore,
        journalFactory: AppleDeviceSyncJournalFactory
    ) -> AppleDeviceSyncBootstrapResult {
        .blocked(
            AppleDeviceSyncBlockedServices(
                replicaID: replicaID,
                reason: reason,
                metadataStore: metadataStore,
                journalFactory: journalFactory
            )
        )
    }

    private static func makeReadyServices(
        containerIdentifier: String,
        metadataStore: AppleDeviceSyncMetadataStore,
        metadata: AppleDeviceSyncMetadataSnapshot,
        accountScope: AppleCloudAccountScope,
        journalFactory: AppleDeviceSyncJournalFactory
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
        let cloudTransport = try await makeCloudTransport(
            containerIdentifier: containerIdentifier,
            safeRoot: safeRoot,
            metadataStore: metadataStore,
            metadata: metadata,
            relay: relay
        )
        let remoteBoundary = AppleDeviceSyncRemoteBoundary(
            transport: cloudTransport,
            accountGate: accountGate
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

    private static func makeCloudTransport(
        containerIdentifier: String,
        safeRoot: URL,
        metadataStore: AppleDeviceSyncMetadataStore,
        metadata: AppleDeviceSyncMetadataSnapshot,
        relay: AppleDeviceSyncSignalRelay
    ) async throws -> CloudKitEpisodeSyncTransport {
        let assetRoot = safeRoot.appendingPathComponent(assetDirectoryName, isDirectory: true)
        let recovered = try await AppleDeviceSyncEngineStateRecovery.make(
            metadataStore: metadataStore,
            metadata: metadata
        ) { restoredState, generation in
            await relay.updateEngineStateGeneration(generation)
            return try CloudKitEpisodeSyncTransport(
                containerIdentifier: containerIdentifier,
                assetRootURL: assetRoot,
                restoredEngineState: restoredState,
                stateSerializationHandler: { state in
                    await relay.persistEngineState(state)
                },
                signalHandler: { signal in
                    await relay.handle(signal)
                }
            )
        }
        return recovered.value
    }

    public func availability() async -> AppleDeviceSyncAvailability {
        await accountGate.availability()
    }
}
