import CloudKit
import Foundation
import NovelSync
import NovelSyncLegacy

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
    private var signInValidationID: UUID?
    private var activeOperations: [UUID: @Sendable () -> Void] = [:]

    init(
        expectedScope: AppleCloudAccountScope,
        scopeResolver: @escaping ScopeResolver
    ) {
        self.expectedScope = expectedScope
        self.scopeResolver = scopeResolver
    }

    func availability() -> AppleDeviceSyncAvailability {
        if signInValidationID != nil {
            return .blocked(.temporarilyUnavailable)
        }
        return currentAvailability
    }

    func requireAvailable() throws {
        if signInValidationID != nil {
            throw AppleDeviceSyncServicesError.blocked(.temporarilyUnavailable)
        }
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
            if case let .blocked(reason) = availability() {
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

    /// A newly-created CKSyncEngine reports the already-signed-in account as a
    /// `.signIn` event when it starts without restored engine state. Fence any
    /// in-flight operation while revalidating that live identity, but keep this
    /// runtime usable when it is still the exact bootstrap account.
    func revalidateForSignIn() async -> AppleDeviceSyncAvailability {
        guard case .ready = currentAvailability else { return currentAvailability }

        let validationID = UUID()
        signInValidationID = validationID
        cancelActiveOperations()

        let currentScope: AppleCloudAccountScope
        do {
            currentScope = try await scopeResolver()
        } catch {
            guard signInValidationID == validationID else { return currentAvailability }
            signInValidationID = nil
            if CloudKitErrorMapper.isTransient(error) {
                // The next remote operation performs the same live identity
                // check. Staying retryable here cannot authorize a write.
                return currentAvailability
            }
            block(.accountUnavailable)
            return currentAvailability
        }

        // The actor can re-enter while the resolver is suspended. A later
        // sign-out/switch fence always wins over this completed validation.
        guard signInValidationID == validationID else { return currentAvailability }
        signInValidationID = nil
        guard currentScope == expectedScope else {
            block(.differentCloudAccount)
            return currentAvailability
        }
        return currentAvailability
    }

    func handleAccountChange(
        _ kind: CloudKitAccountChangeKind
    ) async -> AppleDeviceSyncAvailability {
        switch kind {
        case .signIn:
            await revalidateForSignIn()
        case .signOut:
            blockForAccountChange()
        case .switchAccounts:
            blockForAccountChange(.differentCloudAccount)
        }
    }

    /// CKSyncEngine sign-out/switch events fence immediately. Returning to the
    /// old account never revives this runtime; the factory must recreate it.
    func blockForAccountChange(
        _ reason: AppleDeviceSyncBlockReason = .accountUnavailable
    ) -> AppleDeviceSyncAvailability {
        block(reason)
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
        signInValidationID = nil
        guard case .ready = currentAvailability else { return }
        currentAvailability = .blocked(reason)
        cancelActiveOperations()
    }

    private func cancelActiveOperations() {
        let cancellations = Array(activeOperations.values)
        activeOperations.removeAll()
        for cancel in cancellations {
            cancel()
        }
    }
}
