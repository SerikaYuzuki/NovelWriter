#if canImport(NovelSyncCloudKit)
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
                .appendingPathComponent("SyncWorkingCopies-v2", isDirectory: true),
            fileManager: fileManager
        )
        let localLibraryStore = try DeviceSyncLocalLibraryStore(
            registryRootURL: supportRoot.appendingPathComponent(
                "local-library-registry-v1",
                isDirectory: true
            ),
            trustedAncestorURL: supportRoot.deletingLastPathComponent(),
            workingCopyRoot: workingCopyRoot
        )
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: supportRoot)
        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let runtimeBox = DeviceSyncProductionRuntimeBox(
            localBootstrap: localBootstrap,
            workingCopyRoot: workingCopyRoot,
            localLibraryStore: localLibraryStore,
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
            // R5a: normal production composition is Note-only. Legacy Work
            // transport remains injectable for compatibility/test runtimes
            // until the package target split is completed.
            workTransport: nil,
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
            // D-063の通常targetはcloud libraryだけを作品ライフサイクル入口にする。
            // legacy setupのrandom URLをv2 rootへ作らない。
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

    private static func makeLibraryRuntime(
        runtimeBox: DeviceSyncProductionRuntimeBox,
        localStore: DeviceSyncLocalLibraryStore
    ) -> DeviceSyncLibraryRuntime {
        DeviceSyncLibraryRuntime(
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
            validateInstalledPackage: { try await localStore.validateInstalledPackage(for: $0) },
            reserveForPublish: {
                try await localStore.reserveForPublish(workID: $0, expectedPackage: $1)
            },
            abortPublishReservation: {
                try await localStore.abortPublishReservation(workID: $0)
            },
            confirmPublishPackage: {
                try await localStore.confirmPublishPackage(workID: $0, package: $1)
            },
            attestPublishStaging: {
                try await localStore.attestPublishStaging(workID: $0, package: $1)
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
            markSynced: { try await localStore.markSynced(workID: $0, acknowledgedRemote: $1) },
            markNeedsReview: { try await localStore.markNeedsReview(workID: $0) },
            quarantineInstalledPackage: {
                try await localStore.quarantineInstalledPackage(workID: $0, package: $1)
            },
            recordPackageMutation: {
                try await localStore.recordPackageMutation(workID: $0, package: $1)
            },
            hasLocalPublishAuthority: {
                await runtimeBox.hasLocalPublishAuthority(workID: $0, documentID: $1)
            },
            publishNewWork: { workID, document, url in
                let session = DocumentSessionToken(
                    generation: 0,
                    documentID: document.id,
                    documentURL: url
                )
                let descriptor = try SyncWorkDescriptor(
                    workID: workID,
                    sourceDocumentID: document.id,
                    structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                    title: document.title
                )
                _ = try await runtimeBox.startNew(
                    session: session,
                    descriptor: descriptor,
                    allowedEpisodes: document.chapters.flatMap(\.episodes).map(\.id)
                )
            },
            resumeInitialWorkPublication: { workID, document, url in
                let session = DocumentSessionToken(
                    generation: 0,
                    documentID: document.id,
                    documentURL: url
                )
                let descriptor = try SyncWorkDescriptor(
                    workID: workID,
                    sourceDocumentID: document.id,
                    structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                    title: document.title
                )
                try await runtimeBox.resumeInitialWorkPublication(
                    session: session,
                    descriptor: descriptor,
                    allowedEpisodes: document.chapters.flatMap(\.episodes).map(\.id),
                    initialSnapshot: WorkSnapshot(document: document)
                )
            },
            removeLocalWork: { try await localStore.removeLocalWork(workID: $0) }
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

enum DeviceSyncProductionRuntimeState {
    case starting
    case ready(AppleDeviceSyncServices)
    case blocked(AppleDeviceSyncBlockedServices?)
}

enum DeviceSyncInitialWorkPublicationError: Error, Equatable {
    /// The hidden chooser coordinator may only finish the first local publish.
    /// Any state that has observed a remote head or needs package reconciliation
    /// must be handed to the active document preflight instead.
    case requiresActiveDocumentPreflight
}

actor DeviceSyncProductionRuntimeBox: EpisodeSyncTransport {
    let localBootstrap: AppleDeviceSyncLocalBootstrap
    let workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot
    let localLibraryStore: DeviceSyncLocalLibraryStore
    let signalContinuation: AsyncStream<Void>.Continuation
    var state: DeviceSyncProductionRuntimeState = .starting
    var signalTask: Task<Void, Never>?
    var knownBoundLocators: Set<AppleLocalDocumentLocator> = []
    var pendingWorkPublicationTasks: [SyncWorkID: Task<Void, Error>] = [:]
    var pendingCreateAndBindTasks: [SyncWorkID: Task<AppleResolvedWorkingCopy?, Error>] = [:]
    var bootstrapContainerIdentifier: String?

    init(
        localBootstrap: AppleDeviceSyncLocalBootstrap,
        workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot,
        localLibraryStore: DeviceSyncLocalLibraryStore,
        signalContinuation: AsyncStream<Void>.Continuation
    ) {
        self.localBootstrap = localBootstrap
        self.workingCopyRoot = workingCopyRoot
        self.localLibraryStore = localLibraryStore
        self.signalContinuation = signalContinuation
    }

    deinit {
        signalTask?.cancel()
        signalContinuation.finish()
    }
}

#endif
