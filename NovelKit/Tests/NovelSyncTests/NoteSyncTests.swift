// Projection and dirty-set cases keep exact entity keys in the assertions.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable line_length optional_data_string_conversion
import Foundation
import NovelCore
import NovelSync
import NovelSyncTesting
import Testing

enum NoteSyncFixtures {
    static let workID = WorkTestValues.workID
    static let forkedWorkID = SyncWorkID(rawValue: uuid("A0000000-0000-0000-0000-000000000099"))
    static let episode3 = EpisodeID(rawValue: uuid("20000000-0000-0000-0000-000000000003"))

    static func records(
        _ snapshot: WorkSnapshot,
        workID: SyncWorkID = workID
    ) throws -> [NoteSyncRecord] {
        try NoteSyncProjection.records(workID: workID, snapshot: snapshot)
    }

    static func lastAcked(_ snapshot: WorkSnapshot) throws -> [NoteSyncEntityKey: SyncContentDigest] {
        try Dictionary(uniqueKeysWithValues: records(snapshot).map { ($0.key, $0.digest) })
    }

    static func key(_ kind: NoteSyncEntityKind, _ id: UUID) -> NoteSyncEntityKey {
        NoteSyncEntityKey(workID: workID, kind: kind, entityID: WorkStableID(rawValue: id))
    }

    static func workKey(_ workID: SyncWorkID = workID) -> NoteSyncEntityKey {
        .work(workID)
    }

    static func chapterKey(_ id: ChapterID = WorkTestValues.chapter1) -> NoteSyncEntityKey {
        key(.chapter, id.rawValue)
    }

    static func episodeKey(_ id: EpisodeID = WorkTestValues.episode1) -> NoteSyncEntityKey {
        key(.episode, id.rawValue)
    }

    static func dirty(from previous: WorkSnapshot, to current: WorkSnapshot) throws -> NoteSyncDirtySet {
        try NoteSyncProjection.changes(workID: workID, from: previous, to: current)
    }

    static func delta(_ snapshot: WorkSnapshot) throws -> NoteSyncRemoteDelta {
        try NoteSyncRemoteDelta(upserts: records(snapshot))
    }

    private static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

@Suite("Note sync projection")
struct NoteSyncProjectionTests {
    @Test("snapshot round-trips through entity records without changing document identity")
    func snapshotRoundTrip() throws {
        let snapshot = try WorkTestValues.snapshot()
        let records = try NoteSyncFixtures.records(snapshot)
        let restored = try NoteSyncProjection.snapshot(workID: NoteSyncFixtures.workID, records: records)

        #expect(restored == snapshot)
        #expect(try restored.materializedDocument() == WorkTestValues.fullDocument())
        #expect(records.contains { $0.key == NoteSyncFixtures.workKey() })
        #expect(Set(records.map(\.key.workID)) == Set([NoteSyncFixtures.workID]))
        #expect(records.count(where: { $0.key.kind == .episode }) == 2)
    }

    @Test("body edits dirty only the episode; chapter order dirties work; add and delete dirty structure")
    func dirtyGranularity() throws {
        let base = try WorkTestValues.snapshot()
        let body = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "offline body"
        }
        let reordered = try WorkTestValues.snapshot { document in
            document.chapters.swapAt(0, 1)
        }
        let added = try WorkTestValues.snapshot { document in
            document.chapters[1].episodes.append(
                Episode(id: NoteSyncFixtures.episode3, title: "追加", content: "new", memo: "")
            )
        }
        let removed = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes.removeAll { $0.id == WorkTestValues.episode2 }
        }

        #expect(try NoteSyncFixtures.dirty(from: base, to: body).saves == Set([NoteSyncFixtures.episodeKey()]))
        #expect(try NoteSyncFixtures.dirty(from: base, to: body).deletes.isEmpty)

        #expect(try NoteSyncFixtures.dirty(from: base, to: reordered).saves == Set([NoteSyncFixtures.workKey()]))
        #expect(try NoteSyncFixtures.dirty(from: base, to: reordered).deletes.isEmpty)

        let addedDirty = try NoteSyncFixtures.dirty(from: base, to: added)
        #expect(addedDirty.saves == Set([
            NoteSyncFixtures.chapterKey(WorkTestValues.chapter2),
            NoteSyncFixtures.episodeKey(NoteSyncFixtures.episode3)
        ]))
        #expect(addedDirty.deletes.isEmpty)

        let removedDirty = try NoteSyncFixtures.dirty(from: base, to: removed)
        #expect(removedDirty.saves == Set([NoteSyncFixtures.chapterKey()]))
        #expect(removedDirty.deletes == Set([NoteSyncFixtures.episodeKey(WorkTestValues.episode2)]))
    }
}

@Suite("Note sync reconciler")
struct NoteSyncReconcilerTests {
    @Test("independent entity edits send and apply without conflict or text merge")
    func independentEditsCoexist() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "local body"
        }
        let remote = try WorkTestValues.snapshot { document in
            document.characters[0].name = "remote name"
        }
        let result = try NoteSyncReconciler.reconcile(
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base)
        )

        #expect(result.conflict == nil)
        #expect(result.recordsToSend.map(\.key) == [NoteSyncFixtures.episodeKey()])
        let document = try result.appliedSnapshot.materializedDocument()
        #expect(document.chapters[0].episodes[0].content == "local body")
        #expect(document.characters[0].name == "remote name")
    }

    @Test("the same episode dirty on both sides conflicts and does not merge text")
    func sameEpisodeConflictsWithoutMerge() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "LOCAL ONLY"
        }
        let remote = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "REMOTE ONLY"
            document.characters[0].name = "remote name"
        }
        let result = try NoteSyncReconciler.reconcile(
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base)
        )

        #expect(result.conflict?.keys == Set([NoteSyncFixtures.episodeKey()]))
        #expect(result.recordsToSend.isEmpty)
        let document = try result.appliedSnapshot.materializedDocument()
        #expect(document.chapters[0].episodes[0].content == "LOCAL ONLY")
        #expect(!document.chapters[0].episodes[0].content.contains("REMOTE"))
        #expect(document.characters[0].name == "remote name")
    }

    @Test("keep local sends the conflicted episode and keeps the local manuscript")
    func keepLocalSendsConflictedEntity() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "LOCAL ONLY"
        }
        let remote = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "REMOTE ONLY"
        }
        let conflicted = try NoteSyncReconciler.reconcile(
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base)
        )
        let resolution = try NoteSyncReconciler.resolve(
            .keepLocal,
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base),
            conflictKeys: conflicted.conflict?.keys ?? [],
            newWorkID: NoteSyncFixtures.forkedWorkID
        )

        #expect(try resolution.currentWorkSnapshot.materializedDocument().chapters[0].episodes[0].content == "LOCAL ONLY")
        #expect(resolution.currentSend.map(\.key) == [NoteSyncFixtures.episodeKey()])
        #expect(resolution.currentForceSendKeys == Set([NoteSyncFixtures.episodeKey()]))
        #expect(resolution.forkedWorkID == nil)
    }

    @Test("keep remote installs the cloud episode without keeping a merged body")
    func keepRemoteInstallsCloudEntity() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "LOCAL ONLY"
        }
        let remote = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "REMOTE ONLY"
        }
        let conflicted = try NoteSyncReconciler.reconcile(
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base)
        )
        let resolution = try NoteSyncReconciler.resolve(
            .keepRemote,
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base),
            conflictKeys: conflicted.conflict?.keys ?? [],
            newWorkID: NoteSyncFixtures.forkedWorkID
        )

        #expect(try resolution.currentWorkSnapshot.materializedDocument().chapters[0].episodes[0].content == "REMOTE ONLY")
        #expect(resolution.currentSend.isEmpty)
        #expect(resolution.currentDirty.isEmpty)
        #expect(resolution.currentForceSendKeys.isEmpty)
    }

    @Test("keep both forks the local work identity and keeps the cloud work on the original id")
    func keepBothForksLocalWork() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "LOCAL ONLY"
        }
        let remote = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "REMOTE ONLY"
        }
        let conflicted = try NoteSyncReconciler.reconcile(
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base)
        )
        let resolution = try NoteSyncReconciler.resolve(
            .keepBoth,
            workID: NoteSyncFixtures.workID,
            local: local,
            remote: NoteSyncFixtures.delta(remote),
            dirty: NoteSyncFixtures.dirty(from: base, to: local),
            lastAcked: NoteSyncFixtures.lastAcked(base),
            conflictKeys: conflicted.conflict?.keys ?? [],
            newWorkID: NoteSyncFixtures.forkedWorkID
        )

        #expect(resolution.forkedWorkID == NoteSyncFixtures.forkedWorkID)
        #expect(try resolution.forkedSnapshot?.materializedDocument().chapters[0].episodes[0].content == "LOCAL ONLY")
        #expect(try resolution.currentWorkSnapshot.materializedDocument().chapters[0].episodes[0].content == "REMOTE ONLY")
        #expect(resolution.currentWorkSnapshot.documentID == local.documentID)
        #expect(resolution.forkedSnapshot?.documentID == local.documentID)
        #expect(Set(resolution.forkedRecords.map(\.key.workID)) == Set([NoteSyncFixtures.forkedWorkID]))
        #expect(resolution.forkedRecords.contains { $0.key == .work(NoteSyncFixtures.forkedWorkID) })
    }
}

@Suite("Note sync session and dirty store")
struct NoteSyncSessionTests {
    @Test("offline local save survives restart and is sent without treating missing fetch as a delete")
    func offlineSaveThenSend() async throws {
        let store = InMemoryNoteSyncStateStore()
        let session = NoteSyncSession(workID: NoteSyncFixtures.workID, store: store)
        let base = try WorkTestValues.snapshot()
        _ = try await session.installFromRemote(NoteSyncFixtures.records(base))
        let edited = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "offline body"
        }
        let dirty = try await session.recordLocalSnapshot(edited)
        #expect(dirty.saves == Set([NoteSyncFixtures.episodeKey()]))

        let restarted = NoteSyncSession(workID: NoteSyncFixtures.workID, store: store)
        let pending = try await restarted.reconcile(local: edited, remote: .none)
        #expect(pending.conflict == nil)
        #expect(pending.recordsToSend.map(\.key) == [NoteSyncFixtures.episodeKey()])
        #expect(try pending.appliedSnapshot.materializedDocument().chapters[0].episodes[0].content == "offline body")
    }

    @Test("file dirty set round-trips without copying manuscript bytes")
    func fileDirtySetRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-note-sync-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let store = try FileNoteSyncStateStore(rootURL: root)
        let session = NoteSyncSession(workID: NoteSyncFixtures.workID, store: store)
        let base = try WorkTestValues.snapshot()
        _ = try await session.installFromRemote(NoteSyncFixtures.records(base))
        let edited = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "one\ntwo\nthree CHANGED"
        }
        _ = try await session.recordLocalSnapshot(edited)

        let loaded = try #require(try await store.load(for: NoteSyncFixtures.workID))
        #expect(loaded.dirty.saves == Set([NoteSyncFixtures.episodeKey()]))
        #expect(try loaded.lastAckedDigests.count == (NoteSyncFixtures.records(base).count))

        let url = root
            .appendingPathComponent(NoteSyncFixtures.workID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("note-sync.json")
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("one\\ntwo\\nthree"))
        #expect(!text.contains("CHANGED"))
        #expect(data.count < 16 * 1024)
        #expect(try FileNoteSyncStateStore.makeEncoder().encode(loaded) == data)
    }
}

@Suite("Note sync coordinator and paired devices")
struct NoteSyncCoordinatorPairingTests {
    @Test("two in-memory clients exchange an episode edit without merging text")
    func twoClientsRoundTripEpisodeEdit() async throws {
        let cloud = InMemoryNoteSyncCloud()
        let ownerStore = InMemoryNoteSyncStateStore()
        let followerStore = InMemoryNoteSyncStateStore()
        let owner = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: ownerStore,
            cloud: cloud
        )
        let follower = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: followerStore,
            cloud: cloud
        )
        let base = try WorkTestValues.snapshot()
        _ = try await owner.publishLocal(base)
        let installed = try await follower.installFromRemote()
        #expect(installed == base)

        let edited = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "paired body"
        }
        let send = try await owner.publishLocal(edited)
        #expect(!send.hasConflicts)
        let pulled = try await follower.pullRemote(onto: installed)
        #expect(pulled.conflict == nil)
        #expect(try pulled.appliedSnapshot.materializedDocument().chapters[0].episodes[0].content == "paired body")
    }

    @Test("offline edit then reconnect resends dirty entities; empty fetch is not a delete")
    func offlineThenReconnectResendsDirty() async throws {
        let cloud = InMemoryNoteSyncCloud()
        let store = InMemoryNoteSyncStateStore()
        let coordinator = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: store,
            cloud: cloud
        )
        let base = try WorkTestValues.snapshot()
        _ = try await coordinator.publishLocal(base)
        let edited = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "offline then online"
        }
        _ = try await coordinator.recordPackageSave(edited)
        let send = try await coordinator.publishLocal(edited)
        #expect(send.acceptedSaves.map(\.key) == [NoteSyncFixtures.episodeKey()])
        #expect(!send.hasConflicts)

        await cloud.removeAll()
        let pulled = try await coordinator.pullRemote(onto: edited)
        #expect(pulled.conflict == nil)
        #expect(pulled.keysToDelete.isEmpty)
        #expect(try pulled.appliedSnapshot.materializedDocument().chapters[0].episodes[0].content == "offline then online")
    }

    @Test("process-kill restores the dirty set from disk and resends without copying manuscript bytes")
    func processKillRestoresDirtySet() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-note-kill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileNoteSyncStateStore(rootURL: root)
        let cloud = InMemoryNoteSyncCloud()
        let first = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: store,
            cloud: cloud
        )
        let base = try WorkTestValues.snapshot()
        _ = try await first.publishLocal(base)
        let edited = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "after kill"
        }
        _ = try await first.recordPackageSave(edited)

        let restarted = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: store,
            cloud: cloud
        )
        let send = try await restarted.publishLocal(edited)
        #expect(send.acceptedSaves.map(\.key) == [NoteSyncFixtures.episodeKey()])
        let loaded = try #require(try await store.load(for: NoteSyncFixtures.workID))
        let data = try FileNoteSyncStateStore.makeEncoder().encode(loaded)
        #expect(!String(decoding: data, as: UTF8.self).contains("after kill"))
    }

    @Test("same entity edited on both devices becomes a 3-choice conflict, not a text merge")
    func concurrentEditsConflictWithoutMerge() async throws {
        let cloud = InMemoryNoteSyncCloud()
        let owner = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: InMemoryNoteSyncStateStore(),
            cloud: cloud
        )
        let follower = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: InMemoryNoteSyncStateStore(),
            cloud: cloud
        )
        let base = try WorkTestValues.snapshot()
        _ = try await owner.publishLocal(base)
        _ = try await follower.installFromRemote()

        let ownerEdit = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "OWNER"
        }
        _ = try await owner.publishLocal(ownerEdit)

        let followerEdit = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "FOLLOWER"
        }
        let send = try await follower.publishLocal(followerEdit)
        #expect(send.hasConflicts)
        #expect(send.conflictedKeys.contains(NoteSyncFixtures.episodeKey()))
        let pulled = try await follower.pullRemote(onto: followerEdit)
        #expect(pulled.conflict != nil)
        let document = try pulled.appliedSnapshot.materializedDocument()
        #expect(document.chapters[0].episodes[0].content == "FOLLOWER")
        #expect(!document.chapters[0].episodes[0].content.contains("OWNER"))
    }

    @Test("separate clouds do not mix works across simulated account switch")
    func accountSwitchDoesNotMixWorks() async throws {
        let accountA = InMemoryNoteSyncCloud()
        let accountB = InMemoryNoteSyncCloud()
        let coordinatorA = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: InMemoryNoteSyncStateStore(),
            cloud: accountA
        )
        let snapshot = try WorkTestValues.snapshot()
        _ = try await coordinatorA.publishLocal(snapshot)
        let fromB = try await accountB.fetchAll(for: NoteSyncFixtures.workID)
        #expect(fromB.isEmpty)
        let listedB = try await accountB.listWorkRecords()
        #expect(listedB.isEmpty)
        let listedA = try await accountA.listWorkRecords()
        #expect(listedA.count == 1)
    }

    @Test("first send of already-matching cloud records acks without a 3-choice")
    func identicalUnackedRecordsDoNotBecomeReview() async throws {
        let cloud = InMemoryNoteSyncCloud()
        let owner = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: InMemoryNoteSyncStateStore(),
            cloud: cloud
        )
        let follower = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: InMemoryNoteSyncStateStore(),
            cloud: cloud
        )
        let snapshot = try WorkTestValues.snapshot()
        _ = try await owner.publishLocal(snapshot)
        let send = try await follower.publishLocal(snapshot)
        #expect(!send.hasConflicts)
        let pulled = try await follower.pullRemote(onto: snapshot)
        #expect(pulled.conflict == nil)
    }

    @Test("keepLocal uses presented keys when the session has no pending content conflict")
    func keepLocalUsesPresentedKeysWhenSessionPendingEmpty() async throws {
        let cloud = InMemoryNoteSyncCloud()
        let coordinator = NoteSyncCoordinator(
            workID: NoteSyncFixtures.workID,
            store: InMemoryNoteSyncStateStore(),
            cloud: cloud
        )
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "LOCAL ONLY"
        }
        _ = try await coordinator.recordPackageSave(local)
        let resolution = try await coordinator.resolve(
            .keepLocal,
            local: local,
            newWorkID: NoteSyncFixtures.forkedWorkID,
            expectedKeys: [NoteSyncFixtures.episodeKey()]
        )
        #expect(resolution.currentForceSendKeys == Set([NoteSyncFixtures.episodeKey()]))
        #expect(try resolution.currentWorkSnapshot.materializedDocument().chapters[0].episodes[0].content == "LOCAL ONLY")
    }
}
