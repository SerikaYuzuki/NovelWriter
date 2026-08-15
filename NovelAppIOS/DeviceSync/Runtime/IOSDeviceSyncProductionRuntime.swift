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
        let localLibraryStore = try IOSDeviceSyncLocalLibraryStore(
            registryRootURL: supportRoot.appendingPathComponent(
                "local-library-registry-v1",
                isDirectory: true
            ),
            trustedAncestorURL: supportRoot.deletingLastPathComponent(),
            workingCopyLocation: privateWorkingCopyLocation
        )
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: supportRoot)
        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let runtimeBox = IOSDeviceSyncProductionRuntimeBox(
            localBootstrap: localBootstrap,
            privateWorkingCopyLocation: privateWorkingCopyLocation,
            localLibraryStore: localLibraryStore,
            signalContinuation: streamPair.continuation
        )
        self.runtimeBox = runtimeBox
        runtime = try IOSDeviceSyncRuntime(
            replicaID: localBootstrap.replicaID,
            transport: runtimeBox,
            // R5a: normal production composition is Note-only. Legacy Work
            // transport remains injectable for compatibility/test runtimes
            // until the package target split is completed.
            workTransport: nil,
            localWorkBinding: { workingCopyID, sourceDocumentID, _ in
                try await runtimeBox.resolveLocalWork(
                    workingCopyID: workingCopyID,
                    localSourceDocumentID: sourceDocumentID
                )
            },
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
            setup: nil,
            library: Self.makeLibraryRuntime(
                runtimeBox: runtimeBox,
                localStore: localLibraryStore
            ),
            makeNoteSyncCoordinator: { workID, copyID in
                try await runtimeBox.makeNoteSyncCoordinator(
                    workID: workID,
                    localWorkingCopyID: copyID
                )
            }
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
                _ = try await runtimeBox.startNew(
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

    private static func makeLibraryRuntime(
        runtimeBox: IOSDeviceSyncProductionRuntimeBox,
        localStore: IOSDeviceSyncLocalLibraryStore
    ) -> IOSDeviceSyncLibraryRuntime {
        IOSDeviceSyncLibraryRuntime(
            loadLocalInventory: { try await localStore.inventory() },
            loadRemoteLibrary: { try await runtimeBox.loadLibrary() },
            packageURL: { try await localStore.packageURL(for: $0) },
            workIDForPackageURL: { try await localStore.workID(for: $0) },
            stagingPackageURL: { try await localStore.stagingPackageURL(for: $0) },
            validateStagingPackage: {
                try await localStore.validateStagingPackage(at: $0, for: $1)
            },
            installStagingPackage: {
                try await localStore.installStagingPackage($0, for: $1)
            },
            discardStagingPackage: {
                try await localStore.discardStagingPackage($0, for: $1)
            },
            validateInstalledPackage: {
                try await localStore.validateInstalledPackage(for: $0)
            },
            reserveForPublish: {
                try await localStore.reserveForPublish(workID: $0, expectedPackage: $1)
            },
            abortPublishReservation: {
                try await localStore.abortPublishReservation(workID: $0)
            },
            confirmPublishPackage: {
                try await localStore.confirmPublishPackage(workID: $0, package: $1)
            },
            beginRemoteOpen: { try await localStore.beginRemoteOpen($0) },
            attestRemotePackage: {
                try await localStore.attestRemotePackage(
                    workID: $0,
                    package: $1,
                    expectedRemote: $2
                )
            },
            prepareRemoteOpen: { try await runtimeBox.prepareLibraryOpen($0) },
            resumeRemoteOpen: { try await runtimeBox.resumeLibraryOpen($0) },
            canResumeRemoteOpenOffline: {
                await runtimeBox.canResumeLibraryOpenOffline($0)
            },
            offlineResumableRemoteOpenWorkIDs: {
                await runtimeBox.offlineResumableLibraryOpenWorkIDs()
            },
            hasCompletedRemoteOpenLocally: {
                await runtimeBox.hasCompletedLibraryOpenLocally($0)
            },
            localWorkNeedsReview: {
                try await runtimeBox.libraryWorkNeedsReview(workID: $0, documentID: $1)
            },
            markSynced: {
                try await localStore.markSynced(workID: $0, acknowledgedRemote: $1)
            },
            markNeedsReview: { try await localStore.markNeedsReview(workID: $0) },
            quarantineInstalledPackage: {
                try await localStore.quarantineInstalledPackage(workID: $0, package: $1)
            },
            quarantineForAccount: {
                try await localStore.quarantineForAccount(workID: $0, package: $1)
            },
            restoreRemoteOpenPending: {
                try await localStore.restoreRemoteOpenPending(workID: $0, expectedRemote: $1)
            },
            markLegacyPackageRecovered: {
                try await localStore.markLegacyPackageRecovered(workID: $0, package: $1)
            },
            recordPackageMutation: {
                try await localStore.recordPackageMutation(workID: $0, package: $1)
            },
            hasLocalPublishAuthority: {
                await runtimeBox.hasLocalPublishAuthority(workID: $0, documentID: $1)
            },
            publishNewWork: { workID, document, _ in
                let descriptor = try SyncWorkDescriptor(
                    workID: workID,
                    sourceDocumentID: document.id,
                    structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                    title: document.title
                )
                _ = try await runtimeBox.startNew(
                    workingCopyID: IOSPrivateDocumentID(
                        packageName: "\(workID.rawValue.uuidString).novelpkg"
                    ),
                    descriptor: descriptor,
                    allowedEpisodes: document.chapters.flatMap(\.episodes).map(\.id)
                )
            },
            resumeInitialWorkPublication: { workID, document, _ in
                let descriptor = try SyncWorkDescriptor(
                    workID: workID,
                    sourceDocumentID: document.id,
                    structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                    title: document.title
                )
                try await runtimeBox.resumeInitialWorkPublication(
                    workingCopyID: IOSPrivateDocumentID(
                        packageName: "\(workID.rawValue.uuidString).novelpkg"
                    ),
                    descriptor: descriptor,
                    allowedEpisodes: document.chapters.flatMap(\.episodes).map(\.id),
                    initialSnapshot: WorkSnapshot(document: document)
                )
            },
            removeLocalWork: { try await localStore.removeLocalWork(workID: $0) }
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

enum IOSDeviceSyncInitialWorkPublicationError: Error, Equatable {
    case requiresActiveDocumentPreflight
}

actor IOSDeviceSyncProductionRuntimeBox: EpisodeSyncTransport {
    let localBootstrap: AppleDeviceSyncLocalBootstrap
    let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation
    let localLibraryStore: IOSDeviceSyncLocalLibraryStore
    let signalContinuation: AsyncStream<Void>.Continuation
    var state: IOSDeviceSyncProductionRuntimeState = .starting
    var signalTask: Task<Void, Never>?
    var knownBoundLocators: Set<AppleLocalDocumentLocator> = []
    var pendingWorkPublicationTasks: [SyncWorkID: Task<Void, Error>] = [:]
    var pendingCreateAndBindTasks: [SyncWorkID: Task<AppleResolvedWorkingCopy?, Error>] = [:]
    var bootstrapContainerIdentifier: String?

    init(
        localBootstrap: AppleDeviceSyncLocalBootstrap,
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation,
        localLibraryStore: IOSDeviceSyncLocalLibraryStore,
        signalContinuation: AsyncStream<Void>.Continuation
    ) {
        self.localBootstrap = localBootstrap
        self.privateWorkingCopyLocation = privateWorkingCopyLocation
        self.localLibraryStore = localLibraryStore
        self.signalContinuation = signalContinuation
    }

    deinit {
        signalTask?.cancel()
        signalContinuation.finish()
    }
}

#endif
