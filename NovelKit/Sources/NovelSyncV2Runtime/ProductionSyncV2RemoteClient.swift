import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Strict v2 HTTPS adapter. URL paths and wire validation stay outside the
/// application protocol; canonical command/response bytes are never rebuilt.
actor ProductionSyncV2RemoteClient: SyncV2RemoteClient {
    let origin: ProductionHTTPSOrigin
    let vault: any AuthSessionVault
    let clientVersion: String
    let session: URLSession
    let mediaType = "application/vnd.fuminiwa.sync.v2+jcs"

    init(
        origin: ProductionHTTPSOrigin,
        vault: any AuthSessionVault,
        clientVersion: String = "0.0.0",
        clientPlatform: AuthClientPlatform = .macos,
        session: URLSession? = nil
    ) {
        self.origin = origin
        self.vault = vault
        self.clientVersion = clientVersion
        _ = clientPlatform
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        guard let session = try await vault.load() else {
            throw SyncV2Failure.authenticationRequired
        }
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
}
