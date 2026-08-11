#if canImport(NovelSyncCloudKit)
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

final class IOSDeviceSyncProductionComposition: @unchecked Sendable {
    static let containerIdentifier = "iCloud.dev.serikayuzuki.fuminiwa.sync"

    let runtime: IOSDeviceSyncRuntime
    private let runtimeBox: IOSDeviceSyncProductionRuntimeBox

    init(
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation,
        fileManager: FileManager = .default
    ) throws {
        let supportRoot = try Self.supportRoot(fileManager: fileManager)
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: supportRoot)
        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let runtimeBox = IOSDeviceSyncProductionRuntimeBox(
            localBootstrap: localBootstrap,
            privateWorkingCopyLocation: privateWorkingCopyLocation,
            signalContinuation: streamPair.continuation
        )
        self.runtimeBox = runtimeBox
        runtime = try IOSDeviceSyncRuntime(
            replicaID: localBootstrap.replicaID,
            transport: runtimeBox,
            binding: { workingCopyID, sourceDocumentID, _ in
                try await runtimeBox.resolve(
                    workingCopyID: workingCopyID,
                    localSourceDocumentID: sourceDocumentID
                )
            },
            remoteChangeSignals: streamPair.stream,
            mergeRecoveryStore: IOSFileDeviceSyncMergeRecoveryStore(
                rootURL: supportRoot.appendingPathComponent("merge-recovery-v1", isDirectory: true),
                trustedAncestorURL: supportRoot.deletingLastPathComponent().deletingLastPathComponent()
            ),
            editIntentStore: IOSFileDeviceSyncEditIntentStore(
                rootURL: supportRoot.appendingPathComponent("edit-intent-v1", isDirectory: true),
                trustedAncestorURL: supportRoot.deletingLastPathComponent().deletingLastPathComponent()
            ),
            setup: Self.makeSetupRuntime(runtimeBox: runtimeBox)
        )
    }

    func bootstrap() async {
        await runtimeBox.bootstrap(containerIdentifier: Self.containerIdentifier)
    }

    private static func makeSetupRuntime(
        runtimeBox: IOSDeviceSyncProductionRuntimeBox
    ) -> IOSDeviceSyncSetupRuntime {
        IOSDeviceSyncSetupRuntime(
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

enum IOSDeviceSyncProductionRuntimeState {
    case starting
    case ready(AppleDeviceSyncServices)
    case blocked(AppleDeviceSyncBlockedServices?)
}

actor IOSDeviceSyncProductionRuntimeBox: EpisodeSyncTransport {
    let localBootstrap: AppleDeviceSyncLocalBootstrap
    let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation
    let signalContinuation: AsyncStream<Void>.Continuation
    var state: IOSDeviceSyncProductionRuntimeState = .starting
    var signalTask: Task<Void, Never>?
    var knownBoundLocators: Set<AppleLocalDocumentLocator> = []
    var bootstrapContainerIdentifier: String?

    init(
        localBootstrap: AppleDeviceSyncLocalBootstrap,
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation,
        signalContinuation: AsyncStream<Void>.Continuation
    ) {
        self.localBootstrap = localBootstrap
        self.privateWorkingCopyLocation = privateWorkingCopyLocation
        self.signalContinuation = signalContinuation
    }

    deinit {
        signalTask?.cancel()
        signalContinuation.finish()
    }
}

#endif
