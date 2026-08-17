import NovelAuth
import NovelSyncV2Application

actor ProductionSyncV2RemoteClient: SyncV2RemoteClient {
    private let origin: ProductionHTTPSOrigin
    private let vault: any AuthSessionVault

    init(origin: ProductionHTTPSOrigin, vault: any AuthSessionVault) {
        self.origin = origin
        self.vault = vault
    }

    func execute(
        _ operation: SyncV2RemoteOperation
    ) async throws -> SyncV2RemoteExecution {
        _ = origin
        guard let session = try await vault.load() else {
            throw SyncV2Failure.authenticationRequired
        }
        guard session.syncProtocolEpoch == 2 else {
            throw SyncV2Failure.accountFenceChanged
        }
        if case let .command(planned) = operation {
            guard planned.command.binding.accountId == session.accountID,
                  planned.command.binding.accountFence == session.accountFence,
                  planned.command.binding.protocolEpoch == 2,
                  planned.command.binding.serverInstanceId ==
                  session.serverInstanceID.uuidString.lowercased() else {
                throw SyncV2Failure.accountFenceChanged
            }
        }
        // Concrete production authentication/root/origin are wired here, but
        // the full typed capability + upload + register + publish HTTP runner
        // is intentionally fail-closed until its response decoder lands.
        throw SyncV2Failure.fatal(.productionTransportIncomplete)
    }
}
