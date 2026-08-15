import Foundation
import NovelSync
import NovelSyncLegacy

actor AppleDeviceSyncRemoteBoundary: EpisodeSyncTransport, SyncWorkCatalog,
    SyncWorkLibraryCatalog, WorkSyncTransport, NoteSyncCloudStore {
    private let transport: CloudKitEpisodeSyncTransport
    private let accountGate: AppleDeviceSyncAccountGate

    init(
        transport: CloudKitEpisodeSyncTransport,
        accountGate: AppleDeviceSyncAccountGate
    ) {
        self.transport = transport
        self.accountGate = accountGate
    }

    func fetchSnapshot(for key: EpisodeSyncKey) async throws -> EpisodeRemoteSnapshot {
        do {
            return try await accountGate.performOperation { [transport] in
                try await transport.fetchSnapshot(for: key)
            }
        } catch {
            throw Self.mappedEpisodeTransportError(error)
        }
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for key: EpisodeSyncKey
    ) async throws -> EpisodeRevision {
        do {
            return try await accountGate.performOperation { [transport] in
                try await transport.fetchRevision(id, for: key)
            }
        } catch {
            throw Self.mappedEpisodeTransportError(error)
        }
    }

    func claimLease(_ request: EpisodeLeaseClaimRequest) async throws -> EpisodeLeaseClaimResult {
        do {
            return try await accountGate.performMutation { [transport] in
                try await transport.claimLease(request)
            }
        } catch {
            throw Self.mappedEpisodeTransportError(error)
        }
    }

    func releaseLease(
        key: EpisodeSyncKey,
        expectedAuthority: EpisodeLeaseAuthority
    ) async throws -> EpisodeRemoteSnapshot {
        do {
            return try await accountGate.performMutation { [transport] in
                try await transport.releaseLease(
                    key: key,
                    expectedAuthority: expectedAuthority
                )
            }
        } catch {
            throw Self.mappedEpisodeTransportError(error)
        }
    }

    func publish(_ request: EpisodePublishRequest) async throws -> EpisodePublishResult {
        do {
            return try await accountGate.performMutation { [transport] in
                try await transport.publish(request)
            }
        } catch {
            throw Self.mappedEpisodeTransportError(error)
        }
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        do {
            return try await accountGate.performOperation { [transport] in
                try await transport.fetchSnapshot(for: workID)
            }
        } catch {
            throw Self.mappedWorkTransportError(error)
        }
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        do {
            return try await accountGate.performOperation { [transport] in
                try await transport.fetchRevision(id, for: workID)
            }
        } catch {
            throw Self.mappedWorkTransportError(error)
        }
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        do {
            return try await accountGate.performMutation { [transport] in
                try await transport.publish(request)
            }
        } catch {
            throw Self.mappedWorkTransportError(error)
        }
    }

    func createWork(_ descriptor: SyncWorkDescriptor) async throws {
        try await accountGate.performMutation { [transport] in
            try await transport.createWork(descriptor)
        }
    }

    func listWorks() async throws -> [SyncWorkDescriptor] {
        try await accountGate.performOperation { [transport] in
            try await transport.listWorks()
        }
    }

    func listLibraryWorks() async throws -> [SyncWorkLibraryEntry] {
        try await accountGate.performOperation { [transport] in
            try await transport.listLibraryWorks()
        }
    }

    func fetchNoteWorkDescriptor(_ workID: SyncWorkID) async throws -> SyncWorkDescriptor? {
        try await accountGate.performOperation { [transport] in
            try await transport.fetchNoteWorkDescriptor(workID)
        }
    }

    func fetchLibraryWorks(workIDs: [SyncWorkID]) async throws -> [SyncWorkLibraryEntry] {
        try await accountGate.performOperation { [transport] in
            try await transport.fetchLibraryWorks(workIDs: workIDs)
        }
    }

    func save(
        _ records: [NoteSyncRecord],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult {
        try await accountGate.performMutation { [transport] in
            try await transport.save(
                records,
                expectedDigests: expectedDigests,
                forceOverwrite: forceOverwrite
            )
        }
    }

    func delete(
        _ keys: [NoteSyncEntityKey],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult {
        try await accountGate.performMutation { [transport] in
            try await transport.delete(
                keys,
                expectedDigests: expectedDigests,
                forceOverwrite: forceOverwrite
            )
        }
    }

    func fetchAll(for workID: SyncWorkID) async throws -> [NoteSyncRecord] {
        try await accountGate.performOperation { [transport] in
            try await transport.fetchAll(for: workID)
        }
    }

    func listWorkRecords() async throws -> [NoteSyncRecord] {
        try await accountGate.performOperation { [transport] in
            try await transport.listWorkRecords()
        }
    }

    func fetchNoteRecords(for workID: SyncWorkID) async throws -> [NoteSyncRecord] {
        try await accountGate.performOperation { [transport] in
            try await transport.fetchNoteRecords(for: workID)
        }
    }

    static func mappedEpisodeTransportError(_ error: any Error) -> any Error {
        if CloudKitErrorMapper.isTransient(error) {
            return EpisodeSyncTransportError.unavailable
        }
        guard let servicesError = error as? AppleDeviceSyncServicesError,
              case .blocked = servicesError else { return error }
        // A previously verified writer may continue into its durable offline
        // fork, while a fresh/non-holder App session remains read-only. The
        // App enforces that authority distinction; NovelSync only needs the
        // provider-neutral transport availability signal here.
        return EpisodeSyncTransportError.unavailable
    }

    static func mappedWorkTransportError(_ error: any Error) -> any Error {
        if CloudKitErrorMapper.isTransient(error) {
            return WorkSyncTransportError.unavailable
        }
        guard let servicesError = error as? AppleDeviceSyncServicesError,
              case .blocked = servicesError else { return error }
        return WorkSyncTransportError.unavailable
    }
}
