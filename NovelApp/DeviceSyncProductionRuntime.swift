#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

final class DeviceSyncProductionComposition: @unchecked Sendable {
    static let containerIdentifier = "iCloud.dev.serikayuzuki.fuminiwa.sync"

    let runtime: DeviceSyncRuntime
    private let runtimeBox: DeviceSyncProductionRuntimeBox

    init(fileManager: FileManager = .default) throws {
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
            rootURL: supportRoot.appendingPathComponent("merge-recovery-v1", isDirectory: true),
            trustedAncestorURL: supportRoot.deletingLastPathComponent().deletingLastPathComponent()
        )
        let editIntentStore = try FileDeviceSyncEditIntentStore(
            rootURL: supportRoot.appendingPathComponent("edit-intent-v1", isDirectory: true),
            trustedAncestorURL: supportRoot.deletingLastPathComponent().deletingLastPathComponent()
        )
        runtime = DeviceSyncRuntime(
            replicaID: localBootstrap.replicaID,
            transport: runtimeBox,
            workTransport: runtimeBox,
            localWorkBinding: { session, _ in
                try await runtimeBox.resolveLocalWork(
                    session: session,
                    localSourceDocumentID: session.documentID
                )
            },
            binding: { session, _ in
                try await runtimeBox.resolve(session: session, localSourceDocumentID: session.documentID)
            },
            remoteChangeSignals: streamPair.stream,
            mergeRecoveryStore: recoveryStore,
            editIntentStore: editIntentStore,
            setup: Self.makeSetupRuntime(runtimeBox: runtimeBox, workingCopyRoot: workingCopyRoot)
        )
    }

    func bootstrap() async {
        await runtimeBox.bootstrap(containerIdentifier: Self.containerIdentifier)
    }

    private static func makeSetupRuntime(
        runtimeBox: DeviceSyncProductionRuntimeBox,
        workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot
    ) -> DeviceSyncSetupRuntime {
        DeviceSyncSetupRuntime(
            privateWorkingCopyDestination: { try workingCopyRoot.destination(for: $0) },
            validatePrivateWorkingCopy: { try workingCopyRoot.validateCopiedPackage(at: $0) },
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

enum DeviceSyncProductionRuntimeState {
    case starting
    case ready(AppleDeviceSyncServices)
    case blocked(AppleDeviceSyncBlockedServices?)
}

actor DeviceSyncProductionRuntimeBox: EpisodeSyncTransport, WorkSyncTransport {
    let localBootstrap: AppleDeviceSyncLocalBootstrap
    let workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot
    let signalContinuation: AsyncStream<Void>.Continuation
    var state: DeviceSyncProductionRuntimeState = .starting
    var signalTask: Task<Void, Never>?
    var knownBoundLocators: Set<AppleLocalDocumentLocator> = []
    var bootstrapContainerIdentifier: String?

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
}

#endif
