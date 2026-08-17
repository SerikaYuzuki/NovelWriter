import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies a current FUMINIWA session to the remote adapter.  Implementations
/// must serialize refreshes: the adapter may have several concurrent lanes,
/// but a rotating refresh token may only be consumed once.
public protocol SyncV2SessionProvider: Sendable {
    func session() async throws -> FuminiwaSession
    func refresh(afterUnauthorizedFor session: FuminiwaSession) async throws -> FuminiwaSession
}

/// Production provider.  The coordinator owns refresh-token CAS and binding
/// validation; this actor adds proactive expiry handling and a single-flight
/// gate for simultaneous sync requests.
public actor ProductionSyncV2SessionProvider: SyncV2SessionProvider {
    private let vault: any AuthSessionVault
    private let coordinator: AuthSessionCoordinator?
    private let clock: @Sendable () -> Date
    private let leeway: TimeInterval
    private let proactiveRefresh: Bool
    private var refreshTask: Task<FuminiwaSession, Error>?
    private var refreshTaskID: UUID?

    public init(
        vault: any AuthSessionVault,
        coordinator: AuthSessionCoordinator? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        leeway: TimeInterval = 60,
        proactiveRefresh: Bool = true
    ) {
        self.vault = vault
        self.coordinator = coordinator
        self.clock = clock
        self.leeway = max(0, leeway)
        self.proactiveRefresh = proactiveRefresh
    }

    public init(
        vault: any AuthSessionVault,
        transport: any FuminiwaAuthTransport,
        authLimits: AuthLimits,
        platform: AuthClientPlatform = .macos,
        clock: @escaping @Sendable () -> Date = { Date() },
        leeway: TimeInterval = 60,
        proactiveRefresh: Bool = true
    ) {
        self.vault = vault
        coordinator = AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: authLimits,
            platform: platform,
            clock: clock
        )
        self.clock = clock
        self.leeway = max(0, leeway)
        self.proactiveRefresh = proactiveRefresh
    }

    public func session() async throws -> FuminiwaSession {
        guard let current = try await vault.load() else {
            throw SyncV2Failure.authenticationRequired
        }
        guard current.syncProtocolEpoch == 2 else {
            throw SyncV2Failure.accountFenceChanged
        }
        guard proactiveRefresh,
              current.accessTokenExpiresAt <= clock().addingTimeInterval(leeway) else {
            return current
        }
        // The vault-only initializer is retained for compatibility with
        // transport-isolated fixtures. Production composition uses the
        // transport-backed initializer below; it never skips an expired
        // access token.
        guard coordinator != nil else {
            return current
        }
        return try await refreshSingleFlight(expected: current)
    }

    public func refresh(afterUnauthorizedFor failed: FuminiwaSession) async throws -> FuminiwaSession {
        guard failed.syncProtocolEpoch == 2 else {
            throw SyncV2Failure.accountFenceChanged
        }
        return try await refreshSingleFlight(expected: failed)
    }

    private func refreshSingleFlight(expected: FuminiwaSession) async throws -> FuminiwaSession {
        if let refreshTask {
            let joined = try await refreshTask.value
            return try await validateRefreshResult(joined, expected: expected)
        }
        // Install the task before the first suspension. Otherwise two
        // callers can both load the old vault record and reserve separate
        // rotations during the actor's reentrant await.
        let ownerID = UUID()
        let task = Task { [vault, coordinator] in
            guard let current = try await vault.load() else {
                throw SyncV2Failure.authenticationRequired
            }
            // Another request may have completed the rotation while this
            // task was being scheduled; reuse its result, never rotate twice.
            guard current.binding == expected.binding else {
                throw SyncV2Failure.accountFenceChanged
            }
            if current.accessToken != expected.accessToken {
                return current
            }
            guard let coordinator else {
                throw SyncV2Failure.authenticationRequired
            }
            return try await coordinator.refresh()
        }
        refreshTask = task
        refreshTaskID = ownerID
        do {
            let refreshed = try await task.value
            let validated = try await validateRefreshResult(refreshed, expected: expected)
            if refreshTaskID == ownerID {
                refreshTask = nil
                refreshTaskID = nil
            }
            return validated
        } catch {
            if refreshTaskID == ownerID {
                refreshTask = nil
                refreshTaskID = nil
            }
            if let current = try? await vault.load(),
               current.binding != expected.binding {
                throw SyncV2Failure.accountFenceChanged
            }
            throw error
        }
    }

    private func validateRefreshResult(
        _ refreshed: FuminiwaSession,
        expected: FuminiwaSession
    ) async throws -> FuminiwaSession {
        guard refreshed.binding == expected.binding,
              refreshed.syncProtocolEpoch == 2,
              refreshed.refreshGeneration > expected.refreshGeneration,
              let current = try await vault.load(),
              current.binding == expected.binding else {
            throw SyncV2Failure.accountFenceChanged
        }
        if current.refreshGeneration > refreshed.refreshGeneration {
            return current
        }
        if current.refreshGeneration == refreshed.refreshGeneration {
            guard current.accessToken == refreshed.accessToken,
                  current.refreshToken == refreshed.refreshToken else {
                throw SyncV2Failure.accountFenceChanged
            }
            return current
        }
        return refreshed
    }
}

/// Strict v2 HTTPS adapter. URL paths and wire validation stay outside the
/// application protocol; canonical command/response bytes are never rebuilt.
actor ProductionSyncV2RemoteClient: SyncV2RemoteClient {
    let origin: ProductionHTTPSOrigin
    let sessionProvider: any SyncV2SessionProvider
    let clientVersion: String
    let session: URLSession
    let mediaType = "application/vnd.fuminiwa.sync.v2+jcs"

    init(
        origin: ProductionHTTPSOrigin,
        vault: any AuthSessionVault,
        clientVersion: String = "0.0.0",
        clientPlatform: AuthClientPlatform = .macos,
        session: URLSession? = nil,
        sessionProvider: (any SyncV2SessionProvider)? = nil
    ) {
        self.origin = origin
        self.clientVersion = clientVersion
        _ = clientPlatform
        let configuredSession: URLSession
        if let session {
            configuredSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuredSession = URLSession(configuration: configuration)
        }
        self.session = configuredSession
        if let sessionProvider {
            self.sessionProvider = sessionProvider
        } else {
            // Runtime composition supplies the transport-backed provider.
            // Keep this legacy initializer transport-isolated for fixtures;
            // it deliberately performs no proactive refresh.
            self.sessionProvider = ProductionSyncV2SessionProvider(
                vault: vault,
                proactiveRefresh: false
            )
        }
    }

    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        let session = try await loadSession()
        guard session.syncProtocolEpoch == 2 else {
            throw SyncV2Failure.accountFenceChanged
        }
        switch operation {
        case let .upload(transfer):
            return try await upload(transfer, session: session)
        case let .command(planned):
            let command = planned.command
            guard command.binding.accountId == session.accountID,
                  command.binding.accountFence == session.accountFence,
                  command.binding.protocolEpoch == 2,
                  command.binding.serverInstanceId == session.serverInstanceID.uuidString.lowercased() else {
                throw SyncV2Failure.accountFenceChanged
            }
            let receipt = try await send(command, session: session)
            let shouldFetchInbox = planned.kind == .publish &&
                (receipt.result == .noChanges || receipt.result == .conflictPending)
            return try await .command(
                receipt: receipt,
                remoteInbox: shouldFetchInbox
                    ? inbox(command: command, receipt: receipt, session: session)
                    : nil
            )
        }
    }

    func loadSession() async throws -> FuminiwaSession {
        do {
            return try await sessionProvider.session()
        } catch let error as SyncV2Failure {
            throw error
        } catch {
            // A failed refresh parks only the remote lane.  Local open,
            // checkpoint, and save never depend on this network operation.
            throw SyncV2Failure.authenticationRequired
        }
    }
}

private actor UnavailableSyncV2SessionProvider: SyncV2SessionProvider {
    func session() async throws -> FuminiwaSession {
        throw SyncV2Failure.authenticationRequired
    }

    func refresh(afterUnauthorizedFor _: FuminiwaSession) async throws -> FuminiwaSession {
        throw SyncV2Failure.authenticationRequired
    }
}
