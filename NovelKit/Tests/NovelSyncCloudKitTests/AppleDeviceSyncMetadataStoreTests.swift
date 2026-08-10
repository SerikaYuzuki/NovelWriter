import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync metadata")
struct AppleDeviceSyncMetadataStoreTests {
    @Test("replica, binding, and engine state survive an atomic restart")
    func stableRoundTripIgnoresCrashTemporary() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let scope = accountScope("_defaultOwner")
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.4D875891")
        let workID = SyncWorkID()

        let firstStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let installed = try await firstStore.installAccountScope(scope)
        let binding = try await firstStore.bind(
            locator,
            to: workID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let engineState = Data("engine-state-v1".utf8)
        #expect(
            try await firstStore.saveEngineState(
                engineState,
                generation: installed.engineStateGeneration
            )
        )

        let interruptedTemporary = root.appendingPathComponent(
            ".device-sync-metadata-interrupted.tmp"
        )
        try Data("{truncated".utf8).write(to: interruptedTemporary)

        let restartedStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let restarted = await restartedStore.snapshot()
        #expect(restarted.replicaID == installed.replicaID)
        #expect(restarted.accountScope == scope)
        #expect(restarted.bindings[locator] == binding)
        #expect(restarted.engineState == engineState)
    }

    @Test("normal bind is idempotent but a different work requires explicit rebind")
    func explicitRebindOnly() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(accountScope("account-a"))
        let locator = try AppleLocalDocumentLocator(rawValue: "ios.private-document.A")
        let firstWork = SyncWorkID()
        let secondWork = SyncWorkID()

        let first = try await store.bind(
            locator,
            to: firstWork,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        #expect(
            try await store.bind(
                locator,
                to: firstWork,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            ) == first
        )
        await #expect(throws: AppleDeviceSyncServicesError.locatorAlreadyBound) {
            try await store.bind(
                locator,
                to: secondWork,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            )
        }

        let rebound = try await store.rebind(
            locator,
            to: secondWork,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        #expect(rebound.binding.workID == secondWork)
        #expect(rebound.binding.localWorkingCopyID != first.binding.localWorkingCopyID)
        let reboundAgain = try await store.rebind(
            locator,
            to: secondWork,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        #expect(reboundAgain.binding.workID == secondWork)
        #expect(reboundAgain.binding.localWorkingCopyID != rebound.binding.localWorkingCopyID)
        #expect(try await store.unbind(locator) == reboundAgain.binding)
        #expect(await store.binding(for: locator) == nil)
    }

    @Test("another iCloud account blocks without replacing bindings or identity")
    func accountMismatchIsFailClosed() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let originalScope = accountScope("account-a")
        let original = try await store.installAccountScope(originalScope)
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.account-test")
        let binding = try await store.bind(
            locator,
            to: SyncWorkID(),
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )

        await #expect(
            throws: AppleDeviceSyncServicesError.blocked(.differentCloudAccount)
        ) {
            try await store.installAccountScope(accountScope("account-b"))
        }
        let afterMismatch = await store.snapshot()
        #expect(afterMismatch.replicaID == original.replicaID)
        #expect(afterMismatch.accountScope == originalScope)
        #expect(afterMismatch.bindings[locator] == binding)
    }

    @Test("stale CKSyncEngine callbacks cannot overwrite a newer generation")
    func staleEngineStateIsIgnored() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let installed = try await store.installAccountScope(accountScope("account-a"))
        let oldGeneration = installed.engineStateGeneration
        #expect(
            try await store.saveEngineState(
                Data("old".utf8),
                generation: oldGeneration
            )
        )

        let newGeneration = try await store.invalidateEngineState(
            expectedGeneration: oldGeneration
        )
        #expect(newGeneration != oldGeneration)
        let staleStateWasSaved = try await store.saveEngineState(
            Data("late-old-callback".utf8),
            generation: oldGeneration
        )
        #expect(!staleStateWasSaved)
        let invalidatedSnapshot = await store.snapshot()
        #expect(invalidatedSnapshot.engineState == nil)
        #expect(
            try await store.saveEngineState(
                Data("new".utf8),
                generation: newGeneration
            )
        )
        let updatedSnapshot = await store.snapshot()
        #expect(updatedSnapshot.engineState == Data("new".utf8))
    }

    @Test("metadata and engine state caps preserve the prior atomic document")
    func oversizedStateDoesNotReplaceMetadata() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let installed = try await store.installAccountScope(accountScope("account-a"))
        let original = Data("valid-state".utf8)
        _ = try await store.saveEngineState(
            original,
            generation: installed.engineStateGeneration
        )

        let oversized = Data(
            repeating: 0x41,
            count: AppleDeviceSyncMetadataStore.maximumEngineStateBytes + 1
        )
        await #expect(throws: AppleDeviceSyncServicesError.metadataTooLarge) {
            try await store.saveEngineState(
                oversized,
                generation: installed.engineStateGeneration
            )
        }
        let preservedSnapshot = await store.snapshot()
        #expect(preservedSnapshot.engineState == original)
    }

    @Test("filesystem root and symlink roots are rejected")
    func unsafeRootsAreRejected() throws {
        #expect(throws: AppleDeviceSyncServicesError.unsafeRoot) {
            try AppleDeviceSyncMetadataStore(
                rootURL: URL(fileURLWithPath: "/", isDirectory: true)
            )
        }

        let parent = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: AppleDeviceSyncServicesError.unsafeRoot) {
            try AppleDeviceSyncMetadataStore(rootURL: link)
        }
    }

    @Test("ancestor symlinks are resolved once and the store uses the canonical root")
    func ancestorSymlinkIsCanonicalized() async throws {
        let parent = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(parent) }
        let actualParent = parent.appendingPathComponent("actual", isDirectory: true)
        let parentAlias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualParent,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: parentAlias,
            withDestinationURL: actualParent
        )
        let requestedRoot = parentAlias.appendingPathComponent("device-sync", isDirectory: true)
        let store = try AppleDeviceSyncMetadataStore(rootURL: requestedRoot)
        let safeRoot = await store.safeRootURL()

        #expect(safeRoot == requestedRoot.resolvingSymlinksInPath().standardizedFileURL)
        #expect(
            FileManager.default.fileExists(
                atPath: actualParent
                    .appendingPathComponent("device-sync", isDirectory: true)
                    .appendingPathComponent(AppleDeviceSyncMetadataStore.metadataFileName)
                    .path
            )
        )
    }

    @Test("fresh offline bootstrap distinguishes bound and unbound local copies")
    func offlineBindingPresenceIsFailClosed() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(accountScope("account-a"))
        let boundLocator = try AppleLocalDocumentLocator(rawValue: "mac.document.bound")
        let unboundLocator = try AppleLocalDocumentLocator(rawValue: "mac.document.unbound")
        _ = try await store.bind(
            boundLocator,
            to: SyncWorkID(),
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )

        let restartedStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let snapshot = await restartedStore.snapshot()
        let blocked = AppleDeviceSyncBlockedServices(
            replicaID: snapshot.replicaID,
            reason: .accountUnavailable,
            metadataStore: restartedStore
        )
        #expect(
            await blocked.localStatus(for: boundLocator)
                == .boundAndBlocked(.accountUnavailable)
        )
        #expect(await blocked.localStatus(for: unboundLocator) == .unbound)
    }

    @Test("each local working copy owns an independent recoverable journal scope")
    func journalsAreScopedByLocalWorkingCopy() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let scope = accountScope("account-a")
        _ = try await store.installAccountScope(scope)
        let firstLocator = try AppleLocalDocumentLocator(rawValue: "mac.document.first")
        let secondLocator = try AppleLocalDocumentLocator(rawValue: "mac.document.second")
        let firstBinding = try await store.bind(
            firstLocator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let secondBinding = try await store.bind(
            secondLocator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let gate = AppleDeviceSyncAccountGate(
            expectedScope: scope,
            scopeResolver: { scope }
        )
        let journalRoot = root.appendingPathComponent("journals-v1", isDirectory: true)
        let factory = AppleDeviceSyncJournalFactory(
            rootURL: journalRoot,
            accountGate: gate,
            metadataStore: store
        )
        let firstJournal = try await factory.journal(for: firstBinding.binding)
        let secondJournal = try await factory.journal(for: secondBinding.binding)
        let firstRevision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "10101010-1010-4010-8010-101010101010")),
            parents: [],
            content: "一つ目の作業コピー"
        )
        let secondRevision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "20202020-2020-4020-8020-202020202020")),
            parents: [],
            content: "二つ目の作業コピー"
        )
        let remoteRevision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "30303030-3030-4030-8030-303030303030")),
            parents: [],
            content: "remote本文"
        )
        let firstRecord = try EpisodeSyncJournalRecord(
            key: cloudTestKey,
            branchID: cloudTestBranchID,
            lastKnownRemoteHead: nil,
            localHead: firstRevision,
            pendingRevisions: [firstRevision]
        )
        let secondRecord = try EpisodeSyncJournalRecord(
            key: cloudTestKey,
            branchID: cloudTestBranchID,
            lastKnownRemoteHead: remoteRevision,
            localHead: secondRevision,
            pendingRevisions: [secondRevision],
            conflict: EpisodeConflict(
                base: nil,
                local: secondRevision,
                remote: remoteRevision
            ),
            mode: .forcedFork
        )
        try await firstJournal.save(firstRecord)
        try await secondJournal.save(secondRecord)

        #expect(try await firstJournal.load(for: cloudTestKey)?.localHead == firstRevision)
        let loadedSecond = try await secondJournal.load(for: cloudTestKey)
        #expect(loadedSecond?.localHead == secondRevision)
        #expect(loadedSecond?.conflict?.remote == remoteRevision)

        let freshBinding = try await store.rebind(
            firstLocator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        #expect(
            freshBinding.binding.localWorkingCopyID
                != firstBinding.binding.localWorkingCopyID
        )
        let freshJournal = try await factory.journal(for: freshBinding.binding)
        #expect(try await freshJournal.load(for: cloudTestKey) == nil)

        let secondFile = journalRoot
            .appendingPathComponent(secondBinding.binding.localWorkingCopyID.rawValue.uuidString)
            .appendingPathComponent(cloudTestWorkID.rawValue.uuidString)
            .appendingPathComponent("\(cloudTestEpisodeID.rawValue.uuidString).json")
        _ = try await store.unbind(secondLocator)
        await #expect(throws: AppleDeviceSyncServicesError.bindingNotFound) {
            try await secondJournal.load(for: cloudTestKey)
        }
        #expect(FileManager.default.fileExists(atPath: secondFile.path))
    }

    private func accountScope(_ userRecordName: String) -> AppleCloudAccountScope {
        AppleCloudAccountScope(
            containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
            userRecordName: userRecordName
        )
    }
}

@Suite("Apple Device Sync account gate")
struct AppleDeviceSyncAccountGateTests {
    @Test("a runtime becomes permanently blocked after observing a different account")
    func differentAccountBlocksRuntime() async throws {
        let original = AppleCloudAccountScope(
            containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
            userRecordName: "account-a"
        )
        let box = AccountScopeBox(scope: original)
        let gate = AppleDeviceSyncAccountGate(
            expectedScope: original,
            scopeResolver: { await box.resolve() }
        )
        #expect(await gate.observeAccountChange() == .ready)

        await box.setScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "account-b"
            )
        )
        #expect(
            await gate.observeAccountChange()
                == .blocked(.differentCloudAccount)
        )
        await #expect(
            throws: AppleDeviceSyncServicesError.blocked(.differentCloudAccount)
        ) {
            try await gate.requireAvailable()
        }
    }
}

private actor AccountScopeBox {
    private var scope: AppleCloudAccountScope

    init(scope: AppleCloudAccountScope) {
        self.scope = scope
    }

    func resolve() -> AppleCloudAccountScope {
        scope
    }

    func setScope(_ scope: AppleCloudAccountScope) {
        self.scope = scope
    }
}
