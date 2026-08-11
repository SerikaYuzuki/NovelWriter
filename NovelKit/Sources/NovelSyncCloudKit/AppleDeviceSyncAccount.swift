import CloudKit
import Foundation
import NovelSync

enum AppleCloudAccountScopeResolver {
    static func resolve(containerIdentifier: String) async throws -> AppleCloudAccountScope {
        guard containerIdentifier.hasPrefix("iCloud."),
              containerIdentifier.utf8.count <= 255 else {
            throw CloudKitSyncAdapterError.invalidConfiguration
        }
        let container = CKContainer(identifier: containerIdentifier)
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw mappedAccountError(error)
        }
        switch status {
        case .available:
            break
        case .noAccount:
            throw CloudKitSyncAdapterError.accountUnavailable(.noAccount)
        case .restricted:
            throw CloudKitSyncAdapterError.accountUnavailable(.restricted)
        case .couldNotDetermine:
            throw CloudKitSyncAdapterError.accountUnavailable(.couldNotDetermine)
        case .temporarilyUnavailable:
            throw CloudKitSyncAdapterError.accountUnavailable(.temporarilyUnavailable)
        @unknown default:
            throw CloudKitSyncAdapterError.accountUnavailable(.couldNotDetermine)
        }

        do {
            let userRecordID = try await container.userRecordID()
            return AppleCloudAccountScope(
                containerIdentifier: containerIdentifier,
                userRecordName: userRecordID.recordName
            )
        } catch {
            throw mappedAccountError(error)
        }
    }

    private static func mappedAccountError(_ error: any Error) -> any Error {
        if let adapterError = error as? CloudKitSyncAdapterError {
            return adapterError
        }
        let mapped = CloudKitErrorMapper.map(error)
        if CloudKitErrorMapper.isTransient(error) {
            return CloudKitSyncAdapterError.accountUnavailable(.temporarilyUnavailable)
        }
        return mapped
    }
}

actor AppleDeviceSyncAccountGate {
    typealias ScopeResolver = @Sendable () async throws -> AppleCloudAccountScope

    private let expectedScope: AppleCloudAccountScope
    private let scopeResolver: ScopeResolver
    private var currentAvailability: AppleDeviceSyncAvailability = .ready
    private var activeOperations: [UUID: @Sendable () -> Void] = [:]

    init(
        expectedScope: AppleCloudAccountScope,
        scopeResolver: @escaping ScopeResolver
    ) {
        self.expectedScope = expectedScope
        self.scopeResolver = scopeResolver
    }

    func availability() -> AppleDeviceSyncAvailability {
        currentAvailability
    }

    func requireAvailable() throws {
        guard case .ready = currentAvailability else {
            if case let .blocked(reason) = currentAvailability {
                throw AppleDeviceSyncServicesError.blocked(reason)
            }
            return
        }
    }

    /// CloudKit operationの直前に必ずlive identityを再取得する。
    /// resolver待機中にaccount eventが入った場合も、再開後にcached readyを使わない。
    /// preflight後とCloudKit API内のaccount switchを完全にatomicにはできないが、
    /// accountChangeでin-flight taskをcancelし、post-operationでもfenceを再確認する。
    func performOperation<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await requireCurrentAccountForOperation()

        let operationID = UUID()
        let task = Task<Value, any Error> {
            try Task.checkCancellation()
            return try await operation()
        }
        activeOperations[operationID] = { task.cancel() }
        defer { activeOperations.removeValue(forKey: operationID) }

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try requireAvailable()
            return value
        } catch {
            if case let .blocked(reason) = currentAvailability {
                throw AppleDeviceSyncServicesError.blocked(reason)
            }
            throw error
        }
    }

    func performMutation<Value: Sendable>(
        _ mutation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await performOperation(mutation)
    }

    /// CKSyncEngineのaccountChangeはidentity再取得を待たず即時fenceする。
    /// 元accountへ戻ってもこのruntimeは復活させず、factoryの再作成を要求する。
    func blockForAccountChange() -> AppleDeviceSyncAvailability {
        block(.accountUnavailable)
        return currentAvailability
    }

    private func requireCurrentAccountForOperation() async throws {
        try requireAvailable()
        let currentScope: AppleCloudAccountScope
        do {
            currentScope = try await scopeResolver()
        } catch {
            if CloudKitErrorMapper.isTransient(error) {
                // A temporary account/network lookup failure is not evidence
                // that the signed-in account changed. Keep the gate retryable;
                // the App continues from its durable detached local branch.
                throw error
            }
            block(.accountUnavailable)
            throw AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        }
        try requireAvailable()
        guard currentScope == expectedScope else {
            block(.differentCloudAccount)
            throw AppleDeviceSyncServicesError.blocked(.differentCloudAccount)
        }
    }

    private func block(_ reason: AppleDeviceSyncBlockReason) {
        guard case .ready = currentAvailability else { return }
        currentAvailability = .blocked(reason)
        let cancellations = Array(activeOperations.values)
        activeOperations.removeAll()
        for cancel in cancellations {
            cancel()
        }
    }
}

actor AppleDeviceSyncRemoteBoundary: EpisodeSyncTransport, SyncWorkCatalog {
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
}

actor AppleDeviceSyncJournalBoundary: EpisodeSyncJournal {
    private let journal: FileEpisodeSyncJournal
    private let metadataStore: AppleDeviceSyncMetadataStore
    private let binding: SyncWorkingCopyBinding

    init(
        journal: FileEpisodeSyncJournal,
        metadataStore: AppleDeviceSyncMetadataStore,
        binding: SyncWorkingCopyBinding
    ) {
        self.journal = journal
        self.metadataStore = metadataStore
        self.binding = binding
    }

    func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord? {
        try await requireUsableBinding()
        return try await journal.load(for: key)
    }

    func save(_ record: EpisodeSyncJournalRecord) async throws {
        try await requireUsableBinding()
        try await journal.save(record)
    }

    private func requireUsableBinding() async throws {
        // This boundary is already scoped to a durable local working-copy ID.
        // Remote account availability fences transport creation and writes,
        // but must not disable the current holder's offline fork journal.
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
    }
}

actor AppleDeviceSyncJournalFactory {
    private let rootURL: URL
    private let metadataStore: AppleDeviceSyncMetadataStore
    private var journals: [LocalWorkingCopyID: AppleDeviceSyncJournalBoundary] = [:]

    init(
        rootURL: URL,
        metadataStore: AppleDeviceSyncMetadataStore
    ) {
        self.rootURL = rootURL
        self.metadataStore = metadataStore
    }

    func journal(
        for binding: SyncWorkingCopyBinding
    ) async throws -> any EpisodeSyncJournal {
        // A journal is an app-private durability boundary scoped by the exact
        // local working-copy binding. Cloud account availability only fences
        // remote transport; it must never prevent an existing copy from
        // recording a detached local revision.
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        if let existing = journals[binding.localWorkingCopyID] {
            return existing
        }
        let bindingRoot = rootURL.appendingPathComponent(
            binding.localWorkingCopyID.rawValue.uuidString,
            isDirectory: true
        )
        let fileJournal = try FileEpisodeSyncJournal(rootURL: bindingRoot)
        let boundary = AppleDeviceSyncJournalBoundary(
            journal: fileJournal,
            metadataStore: metadataStore,
            binding: binding
        )
        journals[binding.localWorkingCopyID] = boundary
        return boundary
    }
}
