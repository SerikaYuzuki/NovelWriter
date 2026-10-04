import Foundation
import NovelSyncV2
import NovelSyncV2Application
import Observation

/// Platform-neutral ownership of asynchronous document synchronization. The
/// host still commits IME, saves locally and installs while holding its gate.
@MainActor
@Observable
public final class SyncSessionController<Session: Equatable & Sendable, Account: Equatable & Sendable, OpenResult: Sendable> {
    public init() {}

    public struct OperationContext: Sendable {
        public let workID: WorkID?
        public let session: Session
        public let account: Account
        public let editGeneration: UInt64?

        public init(workID: WorkID?, session: Session, account: Account, editGeneration: UInt64?) {
            self.workID = workID
            self.session = session
            self.account = account
            self.editGeneration = editGeneration
        }

        public func isCurrent(_ current: Self) -> Bool {
            workID == current.workID && session == current.session
                && account == current.account && editGeneration == current.editGeneration
        }
    }

    public var remoteOnlyTask: Task<OpenResult, Never>?
    public var remoteOnlyOwner: UUID?
    public var remoteOnlyWorkID: WorkID?
    public var remoteOnlyStartedAt: Date?
    public var prefetchTask: Task<Void, Never>?
    public var prefetchWorkID: WorkID?
    public var reprojectionTask: Task<Void, Never>?
    public var reprojectionOwner: UUID?
    public var accountGeneration: UInt64 = 0
    public var accountOwner: UUID?
    public var accountTransitionRequested = false
    public var accountTransitionInProgress = false
    public var remoteSuspension: SyncV2AccountTransitionRemoteSuspensionToken?
    private var remoteLeases: Set<SyncV2AccountTransitionRemoteSuspensionToken> = []

    public enum RemoteCancellation {
        case releaseImmediately
        case retainUntilFinished
    }

    public func beginRemoteOnlyOpen(workID: WorkID) -> UUID {
        let owner = UUID()
        remoteOnlyOwner = owner
        remoteOnlyWorkID = workID
        remoteOnlyStartedAt = Date()
        return owner
    }

    public func finishRemoteOnlyOpen(owner: UUID?, preservingPrefetchStart: Bool = false) {
        guard remoteOnlyOwner == owner else { return }
        remoteOnlyOwner = nil
        remoteOnlyTask = nil
        remoteOnlyWorkID = nil
        if !preservingPrefetchStart || prefetchTask == nil {
            remoteOnlyStartedAt = nil
        }
    }

    public func cancelBackgroundOperations(remoteOnly policy: RemoteCancellation) {
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

    public func beginReprojection() -> UUID {
        reprojectionOwner = nil
        reprojectionTask?.cancel()
        let owner = UUID()
        reprojectionOwner = owner
        return owner
    }

    public func finishReprojection(owner: UUID) {
        guard reprojectionOwner == owner else { return }
        reprojectionOwner = nil
        reprojectionTask = nil
    }

    public func startPrefetch(workID: WorkID, operation: @escaping @MainActor () async -> Void) {
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

    public func matchesAccount(_ expected: Account, current: Account, transitionActive: Bool = false) -> Bool {
        !transitionActive && current == expected
    }

    public func beginRemoteSuspension(_ application: SyncV2Application) async -> SyncV2AccountTransitionRemoteSuspensionToken {
        let token = await application.beginAccountTransitionRemoteSuspension()
        remoteLeases.insert(token)
        return token
    }

    @discardableResult
    public func endRemoteSuspension(
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
