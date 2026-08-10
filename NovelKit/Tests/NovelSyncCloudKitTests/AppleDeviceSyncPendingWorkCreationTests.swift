import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync pending work creation")
struct AppleDeviceSyncPendingWorkCreationTests {
    @Test("intent, create acknowledgement loss, and bind restarts reuse the saved work ID")
    func restartWindowsReuseSavedWorkID() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let locator = try AppleLocalDocumentLocator(rawValue: "ios.private-document.pending")
        let descriptor = try makeDescriptor(title: "再開する作品")
        let firstStore = try await preparedStore(root: root)

        // intent直後とremote createのack lossはlocal metadata上は同じ。
        let intent = try await firstStore.preparePendingWorkCreation(
            locator,
            proposedDescriptor: descriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let afterIntentRestart = try AppleDeviceSyncMetadataStore(rootURL: root)
        let changedStructure = try SyncWorkStructureDigest(
            validating: String(repeating: "e", count: 64)
        )
        let newProposal = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: descriptor.sourceDocumentID,
            structureDigest: changedStructure,
            title: "再起動後に改題した作品"
        )
        let newLocalOnlyEpisode = EpisodeID()
        let resumed = try await afterIntentRestart.preparePendingWorkCreation(
            locator,
            proposedDescriptor: newProposal,
            allowedEpisodeIDs: [cloudTestEpisodeID, newLocalOnlyEpisode]
        )
        #expect(resumed == intent)
        #expect(!resumed.allowedEpisodeIDs.contains(newLocalOnlyEpisode))

        let binding = try await bindThenRecoverAfterRestart(
            root: root,
            locator: locator,
            intent: intent,
            changedProposal: newProposal,
            newLocalOnlyEpisode: newLocalOnlyEpisode
        )
        let completedStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let completed = await completedStore.snapshot()
        #expect(completed.bindings[locator] == binding)
        #expect(completed.pendingWorkCreations[locator] == nil)
    }

    @Test("mismatch and pre-bind clear fail closed without changing the intent")
    func mismatchIsFailClosed() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root: root)
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.pending-mismatch")
        let descriptor = try makeDescriptor(title: "固定された作品")
        let intent = try await store.preparePendingWorkCreation(
            locator,
            proposedDescriptor: descriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let differentSource = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: UUID(),
            structureDigest: descriptor.structureDigest,
            title: "途中で変わった作品"
        )

        await #expect(throws: AppleDeviceSyncServicesError.pendingWorkCreationMismatch) {
            try await store.preparePendingWorkCreation(
                locator,
                proposedDescriptor: differentSource,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            )
        }
        await #expect(throws: AppleDeviceSyncServicesError.pendingWorkCreationMismatch) {
            try await store.completePendingWorkCreation(intent)
        }
        let preserved = await store.snapshot()
        #expect(preserved.pendingWorkCreations[locator] == intent)
        #expect(preserved.bindings[locator] == nil)
    }

    @Test("legacy schema-v1 metadata decodes without the additive pending field")
    func legacyMetadataDecodesAdditively() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root: root)
        let installed = await store.snapshot()
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.legacy-v1")
        let binding = try await store.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let engineState = Data("legacy-engine-state".utf8)
        _ = try await store.saveEngineState(
            engineState,
            generation: installed.engineStateGeneration
        )
        let metadataURL = root.appendingPathComponent(
            AppleDeviceSyncMetadataStore.metadataFileName
        )
        var legacy = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        legacy.removeValue(forKey: "pendingWorkCreations")
        try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            .write(to: metadataURL, options: .atomic)

        let restartedStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let snapshot = await restartedStore.snapshot()
        #expect(snapshot.replicaID == installed.replicaID)
        #expect(snapshot.bindings[locator] == binding)
        #expect(snapshot.engineState == engineState)
        #expect(snapshot.pendingWorkCreations.isEmpty)
    }

    @Test("pending intents are unique, bounded, and fail closed as protected local state")
    func pendingIntentsAreBoundedAndProtected() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root: root)
        let firstLocator = try AppleLocalDocumentLocator(rawValue: "pending.0")
        let firstDescriptor = try makeDescriptor(title: "bounded")
        _ = try await store.preparePendingWorkCreation(
            firstLocator,
            proposedDescriptor: firstDescriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let duplicateLocator = try AppleLocalDocumentLocator(rawValue: "pending.duplicate")
        await #expect(throws: AppleDeviceSyncServicesError.metadataTooLarge) {
            try await store.preparePendingWorkCreation(
                duplicateLocator,
                proposedDescriptor: firstDescriptor,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            )
        }
        for index in 1 ..< AppleDeviceSyncMetadataStore.maximumPendingWorkCreationCount {
            let descriptor = try makeDescriptor(title: "bounded")
            _ = try await store.preparePendingWorkCreation(
                AppleLocalDocumentLocator(rawValue: "pending.\(index)"),
                proposedDescriptor: descriptor,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            )
        }
        let overflowDescriptor = try makeDescriptor(title: "overflow")
        await #expect(throws: AppleDeviceSyncServicesError.metadataTooLarge) {
            try await store.preparePendingWorkCreation(
                AppleLocalDocumentLocator(rawValue: "pending.overflow"),
                proposedDescriptor: overflowDescriptor,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            )
        }
        let bootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        #expect(bootstrap.localStatus(for: firstLocator) == .boundAndBlocked(.accountUnavailable))
        #expect(await store.snapshot().pendingWorkCreations.count == 64)
    }

    @Test("a clear write failure keeps the confirmed intent retryable")
    func clearFailureCanRetry() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root: root)
        let locator = try AppleLocalDocumentLocator(rawValue: "pending.clear-failure")
        let descriptor = try makeDescriptor(title: "clear再試行")
        let intent = try await store.preparePendingWorkCreation(
            locator,
            proposedDescriptor: descriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        _ = try await store.bind(
            locator,
            to: descriptor.workID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let metadataURL = root.appendingPathComponent(
            AppleDeviceSyncMetadataStore.metadataFileName
        )
        let durableData = try Data(contentsOf: metadataURL)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createSymbolicLink(
            at: metadataURL,
            withDestinationURL: root.appendingPathComponent("unsafe-clear-target")
        )
        await #expect(throws: AppleDeviceSyncServicesError.metadataWriteFailed) {
            try await store.completePendingWorkCreation(intent)
        }
        try FileManager.default.removeItem(at: metadataURL)
        try durableData.write(to: metadataURL, options: .withoutOverwriting)

        let restarted = try AppleDeviceSyncMetadataStore(rootURL: root)
        #expect(await restarted.pendingWorkCreation(for: locator) == intent)
        #expect(
            try await restarted.completePendingWorkCreationIfConfirmed(
                locator,
                remoteDescriptor: descriptor
            )
        )
        #expect(await restarted.pendingWorkCreation(for: locator) == nil)
    }

    private func preparedStore(root: URL) async throws -> AppleDeviceSyncMetadataStore {
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "account-a"
            )
        )
        return store
    }

    private func bindThenRecoverAfterRestart(
        root: URL,
        locator: AppleLocalDocumentLocator,
        intent: ApplePendingWorkCreationSnapshot,
        changedProposal: SyncWorkDescriptor,
        newLocalOnlyEpisode: EpisodeID
    ) async throws -> AppleDeviceSyncBindingSnapshot {
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let binding = try await store.bind(
            locator,
            to: intent.descriptor.workID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let restarted = try AppleDeviceSyncMetadataStore(rootURL: root)
        let resumed = try await restarted.preparePendingWorkCreation(
            locator,
            proposedDescriptor: changedProposal,
            allowedEpisodeIDs: [cloudTestEpisodeID, newLocalOnlyEpisode]
        )
        #expect(resumed == intent)
        #expect(await restarted.binding(for: locator) == binding.binding)
        #expect(
            try await restarted.completePendingWorkCreationIfConfirmed(
                locator,
                remoteDescriptor: intent.descriptor
            )
        )
        return binding
    }

    private func makeDescriptor(title: String) throws -> SyncWorkDescriptor {
        try SyncWorkDescriptor(
            sourceDocumentID: #require(
                UUID(uuidString: "ABABABAB-ABAB-4BAB-8BAB-ABABABABABAB")
            ),
            structureDigest: SyncWorkStructureDigest(
                validating: String(repeating: "d", count: 64)
            ),
            title: title
        )
    }
}
