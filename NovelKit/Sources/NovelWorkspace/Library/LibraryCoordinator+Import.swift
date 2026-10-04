import NovelSyncV2
import NovelSyncV2Application

@MainActor
public protocol WorkspaceLibraryImportHost: WorkspaceLibraryHost {
    var libraryImportPhases: [WorkID: ImportPhase] { get set }
    var libraryImportFailures: [WorkID: SyncV2Failure] { get set }
    var libraryOpeningWorkID: WorkID? { get }
    func announceLibraryImport(_ message: String)
}

public extension LibraryCoordinator {
    /// One sample is also useful to deterministic tests of monitoring races.
    @discardableResult
    func updateImports(account: WorkspaceAccountScope, host: any WorkspaceLibraryImportHost) async -> Bool {
        let state = await operations.importStates()
        guard !Task.isCancelled, host.operationContext.account == account else { return false }
        var phases = state.phases
        if let opening = host.libraryOpeningWorkID,
           phases[opening] == nil, host.libraryImportPhases[opening]?.stage == .opening {
            phases[opening] = host.libraryImportPhases[opening]
        }
        host.libraryImportPhases = phases
        host.libraryImportFailures = state.failures
        return true
    }

    static func observeImports(
        host: any WorkspaceLibraryImportHost, operations: () -> LibraryOperations?
    ) async {
        let account = host.operationContext.account
        while !Task.isCancelled, host.operationContext.account == account {
            if let operations = operations() {
                guard await LibraryCoordinator(operations: operations).updateImports(account: account, host: host) else { return }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    static func cancelImports(
        operations: LibraryOperations?, controller: SyncSessionController<some Any>, host: any WorkspaceLibraryImportHost
    ) async {
        let account = host.operationContext.account
        let id = controller.prefetchWorkID ?? controller.remoteOnlyWorkID
        let prefetch = controller.prefetchTask
        let opening = controller.remoteOnlyTask
        prefetch?.cancel()
        opening?.cancel()
        if let id {
            await operations?.cancelImport(id)
        }
        if let opening {
            _ = await opening.value
        }
        if let prefetch {
            await prefetch.value
        }
        guard host.operationContext.account == account else { return }
        await host.refreshWorkspaceLibrary()
    }

    func takeOntoDevice(
        workID: WorkID, title: String, controller: SyncSessionController<some Any>, host: any WorkspaceLibraryImportHost
    ) {
        guard controller.prefetchTask == nil, controller.remoteOnlyTask == nil else { return }
        let account = host.operationContext.account
        controller.startPrefetch(workID: workID) { [weak host] in
            guard let host else { return }
            do {
                try await operations.prefetch(workID)
                guard !Task.isCancelled, host.operationContext.account == account else { return }
                await host.refreshWorkspaceLibrary()
                guard !Task.isCancelled, host.operationContext.account == account else { return }
                host.announceLibraryImport("『\(title)』をこの端末に取り込みました")
            } catch {
                guard !Task.isCancelled, host.operationContext.account == account else { return }
                let failure = syncV2FailureKind(error)
                host.libraryImportFailures[workID] = failure
                host.announceLibraryImport(SyncV2LibraryPresentation.importFailure(failure))
            }
        }
    }
}
