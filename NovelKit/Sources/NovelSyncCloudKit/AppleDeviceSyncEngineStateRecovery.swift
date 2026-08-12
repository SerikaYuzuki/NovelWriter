import Foundation

struct AppleDeviceSyncRecoveredRuntime<Value: Sendable>: Sendable {
    let value: Value
    let engineStateGeneration: UInt64
}

enum AppleDeviceSyncEngineStateRecovery {
    typealias Builder<Value: Sendable> = @Sendable (
        _ restoredState: Data?,
        _ generation: UInt64
    ) async throws -> Value

    static func make<Value: Sendable>(
        metadataStore: AppleDeviceSyncMetadataStore,
        metadata: AppleDeviceSyncMetadataSnapshot,
        builder: @escaping Builder<Value>
    ) async throws -> AppleDeviceSyncRecoveredRuntime<Value> {
        do {
            let value = try await builder(
                metadata.engineState,
                metadata.engineStateGeneration
            )
            return AppleDeviceSyncRecoveredRuntime(
                value: value,
                engineStateGeneration: metadata.engineStateGeneration
            )
        } catch CloudKitSyncAdapterError.invalidRestoredEngineState {
            let recoveredGeneration = try await metadataStore.invalidateEngineState(
                expectedGeneration: metadata.engineStateGeneration
            )
            do {
                let value = try await builder(nil, recoveredGeneration)
                return AppleDeviceSyncRecoveredRuntime(
                    value: value,
                    engineStateGeneration: recoveredGeneration
                )
            } catch {
                throw AppleDeviceSyncServicesError.blocked(.runtimeInitializationFailed)
            }
        }
    }
}
