import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime

enum IOSSnapshotSyncOutcome: Equatable, Sendable {
    case notStarted, offline, idle, pending, syncing, conflict, failed
}

func acceptsSnapshotSyncV2ConflictResult(_ result: SyncV2TypedResult) -> Bool {
    switch result {
    case .queued, .noChanges: true
    default: false
    }
}

func acceptsSnapshotSyncV2RemoteOnlyOpen(
    _ opened: SyncV2OpenedWork,
    requestedWorkID: WorkID
) -> Bool {
    opened.workID == requestedWorkID
}

extension IOSDocumentStore {
    /// Retires asynchronous remote-only work before a new document operation
    /// can change the session. The task itself must not clear a newer task's
    /// owner slot from its defer block.
    func cancelSnapshotSyncV2BackgroundOperations() {
        snapshotSyncV2RemoteOnlyOpenToken = nil
        snapshotSyncV2RemoteOnlyOpenTask?.cancel()
        snapshotSyncV2RemoteOnlyOpenTask = nil
        snapshotSyncV2RemoteOnlyReadyWorkID = nil
        snapshotSyncV2ReprojectionToken = nil
        snapshotSyncV2ReprojectionTask?.cancel()
        snapshotSyncV2ReprojectionTask = nil
    }

    func invalidateSnapshotSyncV2AccountOperations() {
        cancelSnapshotSyncV2BackgroundOperations()
        syncV2KeepBothPendingWorkID = nil
        libraryRefreshGeneration &+= 1
        historyRefreshGeneration &+= 1
        syncV2RemoteCatalogIsLoading = false
        advanceDocumentSessionGeneration()
    }

    @discardableResult
    func configureSnapshotSyncV2() async -> Bool {
        if snapshotSyncV2Application != nil {
            return true
        }
        if let task = snapshotSyncV2ConfigurationTask {
            await task.value
            return snapshotSyncV2Application != nil
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { snapshotSyncV2ConfigurationTask = nil }
            do {
                #if FUMINIWA_TEST_COMPOSITION
                guard case let .test(configuration) = runtimeComposition else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                let key = libraryRoot.standardizedFileURL
                if let cached = Self.testRuntimeApplications[key] {
                    snapshotSyncV2Application = cached
                } else {
                    let selectedConfiguration: TestRuntimeConfiguration
                    if let cachedConfiguration = Self.testRuntimeConfigurations[key] {
                        selectedConfiguration = cachedConfiguration
                    } else {
                        Self.testRuntimeConfigurations[key] = configuration
                        selectedConfiguration = configuration
                    }
                    let application = try await SnapshotSyncV2Runtime.makeApplication(
                        mode: .test(selectedConfiguration)
                    )
                    Self.testRuntimeApplications[key] = application
                    snapshotSyncV2Application = application
                }
                #else
                guard case .production = runtimeComposition else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
                if let configuration = try? ProductionRuntimeConfiguration(
                    origin: environment.syncServerURL.flatMap { try? ProductionHTTPSOrigin(url: $0) },
                    vault: makeProductionAuthVault(),
                    documentGate: snapshotSyncV2DocumentGate,
                    clientVersion: "0.1.0", clientPlatform: .ios
                ) {
                    snapshotSyncV2Application = try await SnapshotSyncV2Runtime.makeApplication(
                        mode: .production(configuration)
                    )
                } else {
                    snapshotSyncV2Application = nil
                }
                #endif
            } catch {
                snapshotSyncV2Application = nil
            }
        }
        snapshotSyncV2ConfigurationTask = task
        await task.value
        return snapshotSyncV2Application != nil
    }

    #if !FUMINIWA_TEST_COMPOSITION
    private func makeProductionAuthVault() -> (any AuthSessionVault)? {
        #if canImport(Security)
        KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync.ios")
        #else
        nil
        #endif
    }
    #endif
}
