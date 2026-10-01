import Foundation
import NovelSyncV2
import NovelSyncV2Application
import Observation

/// Platform-neutral ownership of asynchronous document synchronization. The
/// host still commits IME, saves locally and installs while holding its gate.
@MainActor
@Observable
final class SyncSessionController<Session: Equatable & Sendable, Account: Equatable & Sendable, OpenResult: Sendable> {
    struct OperationContext: Sendable {
        let workID: WorkID?
        let session: Session
        let account: Account
        let editGeneration: UInt64?

        func isCurrent(_ current: Self) -> Bool {
            workID == current.workID && session == current.session
                && account == current.account && editGeneration == current.editGeneration
        }
    }

    var remoteOnlyTask: Task<OpenResult, Never>?
    var remoteOnlyOwner: UUID?
    var remoteOnlyWorkID: WorkID?
    var remoteOnlyStartedAt: Date?
    var prefetchTask: Task<Void, Never>?
    var prefetchWorkID: WorkID?
    var reprojectionTask: Task<Void, Never>?
    var reprojectionOwner: UUID?
    var accountGeneration: UInt64 = 0
    var accountOwner: UUID?
    var accountTransitionRequested = false
    var accountTransitionInProgress = false
    var remoteSuspension: SyncV2AccountTransitionRemoteSuspensionToken?
    private var remoteLeases: Set<SyncV2AccountTransitionRemoteSuspensionToken> = []

    enum RemoteCancellation {
        case releaseImmediately
        case retainUntilFinished
    }

    func beginRemoteOnlyOpen(workID: WorkID) -> UUID {
        let owner = UUID()
        remoteOnlyOwner = owner
        remoteOnlyWorkID = workID
        remoteOnlyStartedAt = Date()
        return owner
    }

    func finishRemoteOnlyOpen(owner: UUID?, preservingPrefetchStart: Bool = false) {
        guard remoteOnlyOwner == owner else { return }
        remoteOnlyOwner = nil
        remoteOnlyTask = nil
        remoteOnlyWorkID = nil
        if !preservingPrefetchStart || prefetchTask == nil {
            remoteOnlyStartedAt = nil
        }
    }

    func cancelBackgroundOperations(remoteOnly policy: RemoteCancellation) {
        switch policy {
        case .releaseImmediately:
            let task = remoteOnlyTask
            finishRemoteOnlyOpen(owner: remoteOnlyOwner)
            task?.cancel()
        case .retainUntilFinished:
            if let task = remoteOnlyTask {
                let owner = remoteOnlyOwner
                task.cancel()
                Task { [weak self] in
                    _ = await task.value
                    self?.finishRemoteOnlyOpen(owner: owner)
                }
            }
        }
        reprojectionOwner = nil
        reprojectionTask?.cancel()
        reprojectionTask = nil
    }

    func beginReprojection() -> UUID {
        reprojectionOwner = nil
        reprojectionTask?.cancel()
        let owner = UUID()
        reprojectionOwner = owner
        return owner
    }

    func finishReprojection(owner: UUID) {
        guard reprojectionOwner == owner else { return }
        reprojectionOwner = nil
        reprojectionTask = nil
    }

    func startPrefetch(workID: WorkID, operation: @escaping @MainActor () async -> Void) {
        prefetchWorkID = workID
        remoteOnlyStartedAt = Date()
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                prefetchTask = nil
                prefetchWorkID = nil
                if remoteOnlyTask == nil {
                    remoteOnlyStartedAt = nil
                }
            }
            await operation()
        }
    }

    func matchesAccount(_ expected: Account, current: Account, transitionActive: Bool = false) -> Bool {
        !transitionActive && current == expected
    }

    func beginRemoteSuspension(_ application: SyncV2Application) async -> SyncV2AccountTransitionRemoteSuspensionToken {
        let token = await application.beginAccountTransitionRemoteSuspension()
        remoteLeases.insert(token)
        return token
    }

    @discardableResult
    func endRemoteSuspension(
        _ application: SyncV2Application,
        token: SyncV2AccountTransitionRemoteSuspensionToken,
        resume: Bool
    ) async -> Bool {
        // The application also accepts a lease supplied by an outer auth
        // operation. Its exact-token check remains the release authority.
        let released = await application.endAccountTransitionRemoteSuspension(token, resume: resume)
        if released {
            remoteLeases.remove(token)
        }
        return released
    }
}
