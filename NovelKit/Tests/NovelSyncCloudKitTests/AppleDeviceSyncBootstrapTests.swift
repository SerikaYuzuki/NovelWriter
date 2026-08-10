import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync local bootstrap")
struct AppleDeviceSyncBootstrapTests {
    @Test("sync preparation exposes persistent replica and fail-closed local status")
    func localBootstrapPrecedesCloudAccountLookup() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let first = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        let boundLocator = try AppleLocalDocumentLocator(rawValue: "mac.document.bound")
        let unboundLocator = try AppleLocalDocumentLocator(rawValue: "mac.document.unbound")
        #expect(first.localStatus(for: boundLocator) == .unbound)

        _ = try await first.metadataStore.installAccountScope(accountScope("account-a"))
        _ = try await first.metadataStore.bind(
            boundLocator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let restarted = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)

        #expect(restarted.replicaID == first.replicaID)
        #expect(
            restarted.localStatus(for: boundLocator)
                == .boundAndBlocked(.accountUnavailable)
        )
        #expect(restarted.localStatus(for: unboundLocator) == .unbound)
    }

    @Test("a corrupt restored engine state is invalidated once without losing a binding")
    func corruptEngineStateRecoversWithNilState() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let installed = try await store.installAccountScope(accountScope("account-a"))
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.recovery")
        let binding = try await store.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        _ = try await store.saveEngineState(
            Data("{broken-engine-state".utf8),
            generation: installed.engineStateGeneration
        )
        let corrupt = await store.snapshot()
        let attempts = EngineStateAttemptLog()

        let recovered = try await AppleDeviceSyncEngineStateRecovery.make(
            metadataStore: store,
            metadata: corrupt
        ) { state, generation in
            await attempts.record(state: state, generation: generation)
            _ = try CloudKitChangeTrackingDriver.decodeRestoredState(state)
            return "runtime"
        }

        #expect(recovered.value == "runtime")
        #expect(recovered.engineStateGeneration != corrupt.engineStateGeneration)
        #expect(await attempts.statePresence == [true, false])
        let afterRecovery = await store.snapshot()
        #expect(afterRecovery.replicaID == corrupt.replicaID)
        #expect(afterRecovery.bindings[locator] == binding)
        #expect(afterRecovery.engineState == nil)
    }

    @Test("failure to regenerate without state returns a typed blocked result")
    func secondEngineCreationFailureBlocks() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let installed = try await store.installAccountScope(accountScope("account-a"))
        _ = try await store.saveEngineState(
            Data("{broken-engine-state".utf8),
            generation: installed.engineStateGeneration
        )
        let corrupt = await store.snapshot()

        await #expect(
            throws: AppleDeviceSyncServicesError.blocked(.runtimeInitializationFailed)
        ) {
            let _: AppleDeviceSyncRecoveredRuntime<String> = try await AppleDeviceSyncEngineStateRecovery.make(
                metadataStore: store,
                metadata: corrupt
            ) { state, _ in
                if state != nil {
                    throw CloudKitSyncAdapterError.invalidRestoredEngineState
                }
                throw CloudKitSyncAdapterError.invalidConfiguration
            }
        }
    }

    private func accountScope(_ userRecordName: String) -> AppleCloudAccountScope {
        AppleCloudAccountScope(
            containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
            userRecordName: userRecordName
        )
    }
}

private actor EngineStateAttemptLog {
    private(set) var statePresence: [Bool] = []
    private(set) var generations: [UInt64] = []

    func record(state: Data?, generation: UInt64) {
        statePresence.append(state != nil)
        generations.append(generation)
    }
}
