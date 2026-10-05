import Foundation
import NovelAuth
import NovelSyncV2Application
import Observation

/// Platform ports own editor/SQLite preparation and projection, never auth flow.
@MainActor
public protocol AccountTransitionPort: AnyObject {
    var workspaceModel: WorkspaceModel { get }
    var authSessionCoordinator: AuthSessionCoordinator? { get }
    var snapshotSyncV2Application: SyncV2Application? { get }
    func accountBinding(_ session: FuminiwaSession) -> SyncV2AccountScopeBinding
    func invalidateAccountOperations()
    func beginAccountRemoteSuspension(_ application: SyncV2Application) async -> SyncV2AccountTransitionRemoteSuspensionToken
    func endAccountRemoteSuspension(_ application: SyncV2Application, token: SyncV2AccountTransitionRemoteSuspensionToken, resume: Bool) async
    func accountCheckpoint(_ operation: @MainActor () async -> Bool) async -> Bool
    func installAccountSession(_ session: FuminiwaSession?, state: WorkspaceAuthUIState) async
    func reloadAccountLibrary() async
    func resumeAccountWork() async
    func canExchangeAccountSession(_ provider: AuthProvider) -> Bool
    func exchangeAccountSession(_ provider: AuthProvider) async throws -> FuminiwaSession
    func appleCredentialRevoked() async -> Bool
    func accountFailureMessage(_ error: any Error) -> String
    func showRecoveredAccountFailure(_ message: String)
}

/// D-115: request ownership, lease lifetime and durable publication are shared.
@MainActor
@Observable
public final class AccountTransitionCoordinator {
    private weak var host: (any AccountTransitionPort)?
    public var requestOwner: UUID?
    public var requested = false
    public var inProgress = false
    public var remoteSuspension: SyncV2AccountTransitionRemoteSuspensionToken?
    public private(set) var preparing = false
    @ObservationIgnored public private(set) var revokeTask: Task<Void, Never>?
    @ObservationIgnored private let authGate = AuthOperationGate()
    @ObservationIgnored private var signInRequested = false
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var leaseApplication: SyncV2Application?

    public init(host: any AccountTransitionPort) {
        self.host = host
    }

    @discardableResult
    public func beginRequest() async -> UUID? {
        // Capture the exact owner in the cancellation handler. A delayed cleanup
        // from A must never release B's newer request or lease.
        let owner = UUID()
        return await withTaskCancellationHandler {
            guard let host, !requested, requestOwner == nil, !inProgress, !Task.isCancelled else { return nil }
            operationGeneration &+= 1
            requested = true
            requestOwner = owner
            preparing = true
            host.invalidateAccountOperations()
            if let application = host.snapshotSyncV2Application {
                leaseApplication = application
                let token = await host.beginAccountRemoteSuspension(application)
                guard requestOwner == owner, !Task.isCancelled else {
                    await host.endAccountRemoteSuspension(application, token: token, resume: true)
                    await releaseRequest(owner: owner, resume: true)
                    return nil
                }
                remoteSuspension = token
            }
            return owner
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, !inProgress else { return }
                await releaseRequest(owner: owner, resume: true)
            }
        }
    }

    public func releaseRequest(owner: UUID, resume: Bool) async {
        guard requestOwner == owner else { return }
        if let application = leaseApplication, let token = remoteSuspension, let host {
            await host.endAccountRemoteSuspension(application, token: token, resume: resume)
        }
        guard requestOwner == owner else { return }
        remoteSuspension = nil
        leaseApplication = nil
        requestOwner = nil
        requested = false
        preparing = false
    }

    private func recoverAbandonedRequest() async {
        guard let host, host.workspaceModel.authUIState != .signingIn, !inProgress, !signInRequested else { return }
        if let owner = requestOwner {
            await releaseRequest(owner: owner, resume: true)
        } else if requested {
            requested = false
            preparing = false
        }
    }

    /// Same binding refresh publishes tokens only: no generation or task retirement.
    private enum TransitionOutcome { case committed, unsupported, rejected }

    @discardableResult
    public func transition(to session: FuminiwaSession?, state: WorkspaceAuthUIState, owner: UUID? = nil, resumeRemote: Bool = true) async -> Bool {
        await transitionOutcome(to: session, state: state, owner: owner, resumeRemote: resumeRemote) == .committed
    }

    private func transitionOutcome(to session: FuminiwaSession?, state: WorkspaceAuthUIState, owner: UUID? = nil, resumeRemote: Bool = true) async -> TransitionOutcome {
        guard let host else { return .rejected }
        let unsupported = session != nil && session?.syncProtocolEpoch != 2
        let destination = unsupported ? nil : session
        let destinationState: WorkspaceAuthUIState = unsupported ? .failed(Self.unsupportedMessage) : state
        let previous = host.workspaceModel.authSession
        let oldBinding = previous.map(host.accountBinding)
        let newBinding = destination.map(host.accountBinding)
        let needsBoundary = unsupported || oldBinding != newBinding ||
            previous == nil || destination == nil
        if !needsBoundary {
            guard !requested || (owner != nil && requestOwner == owner) else { return .rejected }
            host.workspaceModel.authSession = destination
            host.workspaceModel.authUIState = destinationState
            return .committed
        }
        let ownsRequest = !requested
        let activeOwner: UUID
        if requested {
            guard !inProgress, let owner, requestOwner == owner else { return .rejected }
            activeOwner = owner
        } else {
            guard owner == nil, let acquired = await beginRequest() else { return .rejected }
            activeOwner = acquired
        }
        let application = host.snapshotSyncV2Application
        let token = remoteSuspension
        let transitioned = await host.accountCheckpoint {
            guard self.requestOwner == activeOwner else { return false }
            if let application {
                guard let token else { return false }
                do {
                    try await application.transitionAccountScopes(
                        from: unsupported ? nil : oldBinding, to: newBinding, suspensionToken: token
                    )
                } catch { return false }
            }
            guard self.requestOwner == activeOwner else { return false }
            await host.installAccountSession(destination, state: destinationState)
            return true
        }
        if transitioned {
            await host.reloadAccountLibrary()
        }
        if ownsRequest {
            await releaseRequest(owner: activeOwner, resume: !transitioned)
            if transitioned, !unsupported, resumeRemote {
                await host.resumeAccountWork()
            }
        }
        return transitioned ? (unsupported ? .unsupported : .committed) : .rejected
    }

    /// Refreshes a live scope without opening a request window or retiring work.
    @discardableResult
    public func refresh() async -> Bool {
        guard let host, !requested, let previous = host.workspaceModel.authSession,
              let coordinator = host.authSessionCoordinator else { return false }
        do {
            let refreshed = try await coordinator.refresh()
            guard !requested, host.workspaceModel.authSession?.binding == previous.binding,
                  host.accountBinding(refreshed) == host.accountBinding(previous) else { return false }
            return await transition(to: refreshed, state: .signedIn(accountID: refreshed.accountID))
        } catch { return false }
    }

    public func restore() async {
        await authGate.perform { await self.restoreOwned() }
    }

    private func restoreOwned() async {
        guard let host, let owner = await beginRequest() else { return }
        guard let coordinator = host.authSessionCoordinator else {
            let parked = await transition(to: nil, state: .unavailable, owner: owner)
            await releaseRequest(owner: owner, resume: !parked)
            return
        }
        do {
            let session = try await coordinator.currentSession()
            if session?.syncProtocolEpoch != nil, session?.syncProtocolEpoch != 2 {
                let outcome = await transitionOutcome(to: session, state: .failed(Self.unsupportedMessage), owner: owner)
                // False is a typed failure; only a successful park permits vault removal.
                if outcome == .unsupported {
                    try await coordinator.prepareSignOut()
                    await releaseRequest(owner: owner, resume: false)
                    startRevoke(coordinator, reportingFailure: false)
                } else {
                    await releaseRequest(owner: owner, resume: true)
                }
                return
            }
            let revoked = await host.appleCredentialRevoked()
            let destination = revoked ? nil : session
            let state = destination.map { WorkspaceAuthUIState.signedIn(accountID: $0.accountID) } ?? .signedOut
            let transitioned = await transition(to: destination, state: state, owner: owner)
            if transitioned, revoked {
                try await coordinator.prepareSignOut()
            }
            await releaseRequest(owner: owner, resume: !transitioned)
            if transitioned {
                if revoked {
                    startRevoke(coordinator)
                } else {
                    await host.resumeAccountWork()
                }
            }
        } catch {
            let parked = await transition(to: nil, state: .failed("サインイン状態を復元できませんでした"), owner: owner)
            await releaseRequest(owner: owner, resume: !parked)
        }
    }

    @discardableResult
    public func signIn(_ provider: AuthProvider) async -> Bool {
        guard let host, host.canExchangeAccountSession(provider) else {
            host?.workspaceModel.authUIState = .unavailable
            return false
        }
        guard !signInRequested, host.workspaceModel.authUIState != .signingIn else { return false }
        await recoverAbandonedRequest()
        signInRequested = true
        defer { signInRequested = false }
        return await authGate.perform { await self.signInOwned(provider) }
    }

    private func signInOwned(_ provider: AuthProvider) async -> Bool {
        guard let host, let owner = await beginRequest() else { return false }
        let previous = host.workspaceModel.authSession
        let previousState = host.workspaceModel.authUIState
        host.workspaceModel.authUIState = .signingIn
        guard await host.accountCheckpoint({ true }),
              await transition(to: nil, state: .signingIn, owner: owner) else {
            host.workspaceModel.authUIState = previousState
            await releaseRequest(owner: owner, resume: true)
            return false
        }
        preparing = false
        do {
            let destination = try await host.exchangeAccountSession(provider)
            guard await transition(to: destination, state: .signedIn(accountID: destination.accountID), owner: owner) else {
                await recoverExchange(fallback: previous, owner: owner, message: "新しいログインセッションを適用できませんでした")
                return false
            }
            await releaseRequest(owner: owner, resume: false)
            await host.resumeAccountWork()
            return true
        } catch is CancellationError {
            await recoverExchange(fallback: previous, owner: owner, message: nil)
        } catch {
            await recoverExchange(fallback: previous, owner: owner, message: host.accountFailureMessage(error))
        }
        return false
    }

    private func recoverExchange(fallback: FuminiwaSession?, owner: UUID, message: String?) async {
        guard let host, requestOwner == owner else { return }
        let saved = try? await host.authSessionCoordinator?.currentSession()
        let destination = saved ?? fallback
        let recovered: Bool
        if let destination {
            recovered = await transition(to: destination, state: .signedIn(accountID: destination.accountID), owner: owner)
        } else {
            recovered = false
            host.workspaceModel.authUIState = message.map { .failed($0) } ?? .signedOut
        }
        if let message, destination != nil {
            if recovered {
                host.showRecoveredAccountFailure(message)
            } else {
                host.workspaceModel.authUIState = .failed(message)
            }
        }
        await releaseRequest(owner: owner, resume: false)
        if recovered {
            await host.resumeAccountWork()
        }
        await host.reloadAccountLibrary()
    }

    public func signOut() async {
        // FIFO behind the exchange preserves the user's sign-out intent.
        await authGate.perform {
            guard let host = self.host, let owner = await self.beginRequest() else { return }
            let parked = await self.transition(to: nil, state: host.authSessionCoordinator == nil ? .unavailable : .signedOut, owner: owner)
            guard parked else {
                await self.releaseRequest(owner: owner, resume: true)
                return
            }
            do {
                // Reserve/remove the exact vault session before allowing a new login.
                // Only the network replay is detached; it can never sign out newer B.
                try await host.authSessionCoordinator?.prepareSignOut()
            } catch {
                host.workspaceModel.authUIState = .failed("サインアウトの同期は保留中です")
                await self.releaseRequest(owner: owner, resume: false)
                return
            }
            await self.releaseRequest(owner: owner, resume: false)
            if let coordinator = host.authSessionCoordinator {
                self.startRevoke(coordinator)
            }
        }
    }

    public func retryPendingRevoke() {
        guard let coordinator = host?.authSessionCoordinator else { return }
        startRevoke(coordinator)
    }

    private func startRevoke(_ coordinator: AuthSessionCoordinator, reportingFailure: Bool = true) {
        guard revokeTask == nil else { return }
        let generation = operationGeneration
        revokeTask = Task { @MainActor [weak self] in
            defer { self?.revokeTask = nil }
            do {
                guard try await coordinator.hasPendingRevoke() else { return }
                try await coordinator.resumePendingRevoke()
                if reportingFailure, self?.operationGeneration == generation, self?.requested == false, let host = self?.host, host.workspaceModel.authSession == nil {
                    host.workspaceModel.authUIState = .signedOut
                }
            } catch {
                if reportingFailure, self?.operationGeneration == generation, self?.requested == false, let host = self?.host, host.workspaceModel.authSession == nil {
                    host.workspaceModel.authUIState = .failed("サインアウトの同期は保留中です")
                }
            }
        }
    }

    private static let unsupportedMessage = "このバージョンの同期セッションには対応していません"
}
