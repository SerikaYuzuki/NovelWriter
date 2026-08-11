import EditorKit
import Foundation
import NovelCore
import NovelSync
import NovelSyncTesting
import Testing

@MainActor
@Suite("Device Sync app integration", .serialized)
struct DeviceSyncAppIntegrationTests {
    @Test("離れた日本語編集は自動統合した確認用下書きになる")
    func disjointJapaneseConflictCreatesAutomaticDraft() throws {
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
        let base = try revision(
            key: key,
            parents: [],
            content: "吾輩は猫である。名前はまだない。"
        )
        let local = try revision(
            key: key,
            parents: [base.revisionID],
            content: "吾輩は黒猫である。名前はまだない。"
        )
        let remote = try revision(
            key: key,
            parents: [base.revisionID],
            content: "吾輩は猫である。名前はまだ無い。"
        )

        let draft = DeviceSyncConflictDraft(
            conflict: EpisodeConflict(base: base, local: local, remote: remote)
        )

        #expect(draft.kind == .automaticIntegration)
        #expect(draft.content == "吾輩は黒猫である。名前はまだ無い。")
        #expect(draft.title == "自動統合の下書き")
    }

    @Test("runtime未設定なら従来どおりlocal本文を編集できる")
    func localOnlyDocumentRemainsEditable() async throws {
        let fixture = makeFixture(content: "local")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository)

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)

        #expect(state.deviceSyncState == .unconfigured)
        #expect(state.deviceSyncAllowsEditing(for: lookup))
    }

    @Test("remote状態はlocal editorの入力可否を変えない")
    func remoteStateNeverLocksLocalEditor() async throws {
        let fixture = makeFixture(content: "local-first")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository)

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: lookup.episodeID)
        let local = try revision(key: key, parents: [], content: "local")
        let remote = try revision(key: key, parents: [], content: "remote")
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)

        for remoteState in [
            DeviceSyncUIState.readOnly,
            .forcing,
            .offlineLocal,
            .conflict(conflict),
            .syncing,
            .blocked
        ] {
            state.deviceSyncState = remoteState
            #expect(state.deviceSyncAllowsEditing(for: lookup))
        }
    }

    @Test("保存記号は端末保存・iCloud・オフライン・統合必要をVoiceOverで区別する")
    func editorStatusDistinguishesDurabilityAndPropagation() throws {
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
        let local = try revision(key: key, parents: [], content: "local")
        let remote = try revision(key: key, parents: [], content: "remote")
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)

        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .unconfigured,
            transferState: .notApplicable,
            localDurability: .notApplicable
        ).accessibilityLabel == "この端末に保存済み")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .writer,
            transferState: .upToDate,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、iCloudにも同期済み")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .offlineLocal,
            transferState: .localPending,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、オフライン")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .conflict(conflict),
            transferState: .localPending,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、統合が必要")
        #expect(DeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .blocked,
            transferState: .notApplicable,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、同期設定を確認")

        let pendingReview = DeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .pending,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: true,
            reviewChanges: {}
        )
        #expect(pendingReview.resolvedStatus == .savingLocally)
        let failedReview = DeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .failed,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: false,
            reviewChanges: {}
        )
        #expect(failedReview.resolvedStatus == .localSaveError)
        let durableReview = DeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .saved,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: true,
            reviewChanges: {}
        )
        #expect(durableReview.resolvedStatus == .needsReview)
    }

    @Test("本文WALは最新一件だけを保持し再起動sequenceとJSON escape境界を安全に読む")
    func productionEditIntentStoreKeepsOnlyLatestBody() async throws {
        let fileManager = FileManager.default
        let trusted = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-WAL-Latest-\(UUID().uuidString)", isDirectory: true)
        let root = trusted
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("DeviceSync-v1", isDirectory: true)
        try fileManager.createDirectory(at: trusted, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: trusted) }
        let store = try FileDeviceSyncEditIntentStore(rootURL: root, trustedAncestorURL: trusted)
        let documentID = UUID()
        let episodeID = EpisodeID()
        let old = editIntentMarker(content: "old", sequence: 100, documentID: documentID, episodeID: episodeID)
        let latest = editIntentMarker(content: "latest", sequence: 101, documentID: documentID, episodeID: episodeID)

        try await store.save(old)
        try await store.save(latest)
        try await store.remove(old)
        var loaded = try await store.load(
            workingCopyIdentity: latest.workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        #expect(loaded == [latest])

        for sequence in 102 ... 1000 {
            try await store.save(editIntentMarker(
                content: "body-\(sequence)",
                sequence: UInt64(sequence),
                documentID: documentID,
                episodeID: episodeID
            ))
        }
        loaded = try await store.load(
            workingCopyIdentity: latest.workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "body-1000")
        #expect(try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)

        let escapedEpisodeID = EpisodeID()
        let escapedBody = String(repeating: "\u{0000}", count: 1_048_576)
        let escaped = editIntentMarker(
            content: escapedBody,
            sequence: 1,
            documentID: documentID,
            episodeID: escapedEpisodeID
        )
        try await store.save(escaped)
        #expect(try await store.load(
            workingCopyIdentity: escaped.workingCopyIdentity,
            documentID: documentID,
            episodeID: escapedEpisodeID
        ) == [escaped])

        let oversized = editIntentMarker(
            content: String(repeating: "x", count: 1_048_577),
            sequence: 2,
            documentID: documentID,
            episodeID: EpisodeID()
        )
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            try await store.save(oversized)
        }
    }

    @Test("本文WALは中間symlink・root差し替え・最終symlinkを拒否する")
    func productionEditIntentStorePinsTrustedRoot() async throws {
        let fileManager = FileManager.default
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-WAL-Root-\(UUID().uuidString)", isDirectory: true)
        let trusted = base.appendingPathComponent("trusted", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: trusted, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let linkedParent = trusted.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try FileDeviceSyncEditIntentStore(
                rootURL: linkedParent.appendingPathComponent("DeviceSync-v1", isDirectory: true),
                trustedAncestorURL: trusted
            )
        }

        let root = trusted.appendingPathComponent("pinned", isDirectory: true)
        let store = try FileDeviceSyncEditIntentStore(rootURL: root, trustedAncestorURL: trusted)
        let marker = editIntentMarker(content: "safe", sequence: 1)
        let moved = trusted.appendingPathComponent("moved", isDirectory: true)
        try fileManager.moveItem(at: root, to: moved)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            try await store.save(marker)
        }

        let finalRoot = trusted.appendingPathComponent("final", isDirectory: true)
        let finalStore = try FileDeviceSyncEditIntentStore(rootURL: finalRoot, trustedAncestorURL: trusted)
        try await finalStore.save(marker)
        let recordURL = try #require(
            fileManager.contentsOfDirectory(at: finalRoot, includingPropertiesForKeys: nil).first
        )
        try fileManager.removeItem(at: recordURL)
        let forged = outside.appendingPathComponent("forged.json")
        try Data("forged".utf8).write(to: forged)
        try fileManager.createSymbolicLink(at: recordURL, withDestinationURL: forged)
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try await finalStore.load(
                workingCopyIdentity: marker.workingCopyIdentity,
                documentID: marker.documentID,
                episodeID: marker.episodeID
            )
        }
    }

    @Test("同一sequenceの異なる本文または復旧参照でWALを上書きしない")
    func editIntentStoreRejectsDifferentPayloadAtSameSequence() async throws {
        let store = InMemoryDeviceSyncEditIntentStore()
        let documentID = UUID()
        let episodeID = EpisodeID()
        let first = editIntentMarker(
            content: "first",
            sequence: 1,
            documentID: documentID,
            episodeID: episodeID
        )
        _ = try await store.save(
            first,
            baselinePackageDigest: SyncContentDigest(content: "base")
        )
        let differentContent = editIntentMarker(
            content: "second",
            sequence: 1,
            documentID: documentID,
            episodeID: episodeID
        )
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try await store.save(
                differentContent,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
        }
        var differentResolution = first
        differentResolution.resolvesPreservedSequences = [1]
        await #expect(throws: DeviceSyncLocalPersistenceError.self) {
            _ = try await store.save(
                differentResolution,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
        }
    }

    @Test("初回本文WALだけが残った再起動はbase一致時だけ最新本文を復元する")
    func firstBoundIntentRecoversBeforeAnyJournalBaseline() async throws {
        let fixture = makeFixture(content: "P0 package")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let resolver = DelayedDeviceSyncBindingResolver()
        let replicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: replicaID,
                transport: server,
                binding: { session, _ in
                    await resolver.resolve(session)
                },
                editIntentStore: editIntents
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let session = state.documentSessionToken
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: session),
            documentID: session.documentID,
            episodeID: episodeID,
            editorContentGeneration: state.editorContentGeneration,
            mutationSequence: 2,
            createdAt: Date(timeIntervalSince1970: 2),
            replicaID: replicaID,
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            workID: resolution.binding.workID,
            baseContentDigest: SyncContentDigest(content: "P0 package"),
            acceptedPriorPackageDigests: [SyncContentDigest(content: "P0 package")],
            content: "P2 WAL latest",
            contentDigest: SyncContentDigest(content: "P2 WAL latest")
        )
        try await editIntents.save(marker)
        await repository.pauseNextSave()

        let originalLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let firstPreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: originalLookup)
        }
        try #require(await repository.waitUntilSaveIsPaused())
        let recoveredLookup = try #require(state.currentDeviceSyncLookupIdentity)
        #expect(recoveredLookup != originalLookup)
        let duplicatePreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: recoveredLookup)
        }
        await Task.yield()
        #expect(await resolver.observedLookupCount() == 0)
        await repository.resumePausedSave()
        try #require(await resolver.waitUntilFirstLookupIsPaused())
        #expect(await resolver.observedLookupCount() == 1)
        await resolver.resumeFirstLookup(with: resolution)
        await firstPreparation.value
        await duplicatePreparation.value

        let package = try await repository.load(from: fixture.url)
        let record = try #require(await journal.storedRecord(
            for: EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        ))
        #expect(state.document.episode(episodeID)?.episode.content == "P2 WAL latest")
        #expect(package.episode(episodeID)?.episode.content == "P2 WAL latest")
        #expect(record.localHead.content == "P2 WAL latest")
        #expect(await server.currentHead(for: record.key)?.content == "P2 WAL latest")
        #expect(await resolver.observedLookupCount() == 1)
        #expect(try await editIntents.load(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        ).isEmpty)
    }

    @Test("本文WAL失敗後のpackage checkpointだけでも再起動時に明示編集を復元する")
    func packageCheckpointRecoversEditWhenIntentMarkerWasNotSaved() async throws {
        let fixture = makeFixture(content: "package survived")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let runtime = DeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let first = makeState(repository: repository, runtime: runtime)
        #expect(await first.openDocument(at: fixture.url))
        let session = first.documentSessionToken
        let checkpoint = DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: first.deviceSyncWorkingCopyIdentity(for: session),
            documentID: session.documentID,
            episodeID: episodeID,
            sequence: 1,
            contentDigest: SyncContentDigest(content: "package survived"),
            containsLocalEditIntent: true
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: fixture.url))
        try await relaunched.prepareDeviceSync(
            for: #require(relaunched.currentDeviceSyncLookupIdentity)
        )

        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        )?.content == "package survived")
        let persisted = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
        #expect(persisted.committedPackage?.containsLocalEditIntent == false)
    }

    @Test("隔離した本文は未設定作品で編集を続けても削除・remote送信しない")
    func preservedRecoveryRemainsUntilRemoteAcknowledgement() async throws {
        let fixture = makeFixture(content: "current package")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let runtimeReplicaID = SyncReplicaID()
        let runtime = DeviceSyncRuntime(
            replicaID: runtimeReplicaID,
            transport: server,
            binding: { _, _ in nil },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "current package"),
            acceptedPriorPackageDigests: nil,
            content: "preserved body",
            contentDigest: SyncContentDigest(content: "preserved body")
        )
        _ = try await editIntents.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "current package")
        )

        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)
        #expect(state.deviceSyncState == .needsReview)
        #expect(state.deviceSyncAllowsEditing(for: lookup))
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)

        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(snapshot.preservedMarkers == [marker])
        #expect(state.deviceSyncLocalRecoveryReview != nil)
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        ) == nil)
    }

    @Test("隔離上限では4本文を保持して選択・remote送信を拒否する")
    func preservedRecoveryCapacityFailsClosedWithoutOverwritingActiveEvidence() async throws {
        let fixture = makeFixture(content: "package body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in nil },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let workingCopyIdentity = state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession)
        let marker: (UInt64) -> DeviceSyncEditIntentMarker = { sequence in
            let content = "recovery body \(sequence)"
            return DeviceSyncEditIntentMarker(
                protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
                workingCopyIdentity: workingCopyIdentity,
                documentID: lookup.documentSession.documentID,
                episodeID: episodeID,
                editorContentGeneration: lookup.editorContentGeneration,
                mutationSequence: sequence,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                replicaID: SyncReplicaID(),
                localWorkingCopyID: nil,
                workID: nil,
                baseContentDigest: SyncContentDigest(content: "package body"),
                acceptedPriorPackageDigests: nil,
                content: content,
                contentDigest: SyncContentDigest(content: content)
            )
        }
        for sequence in 1 ... 3 {
            let evidence = marker(UInt64(sequence))
            _ = try await editIntents.save(
                evidence,
                baselinePackageDigest: SyncContentDigest(content: "package body")
            )
            try await editIntents.preserveForReview(evidence)
        }
        let active = marker(4)
        _ = try await editIntents.save(
            active,
            baselinePackageDigest: SyncContentDigest(content: "package body")
        )

        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)
        #expect(review.preservedMarkers.count == 4)
        #expect(state.deviceSyncLocalRecoveryPending)
        #expect(state.deviceSyncLocalDurabilityState == .failed)
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)

        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID
        )
        #expect(snapshot.preservedMarkers.count == 3)
        #expect(snapshot.marker == active)
        #expect(state.document.episode(episodeID)?.episode.content == "package body")
        #expect(state.activeDeviceSyncIdentity == nil)
    }

    @Test("隔離本文はpackage・journal・remote確認後だけまとめて削除する")
    func preservedRecoveryClearsAfterRemoteAcknowledgement() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "preserved body",
            contentDigest: SyncContentDigest(content: "preserved body")
        )
        _ = try await editIntents.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)

        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        for _ in 0 ..< 100 where state.deviceSyncLocalRecoveryReview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "accepted body")
        #expect(state.deviceSyncLocalRecoveryReview == nil)
        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(snapshot.preservedMarkers.isEmpty)
    }

    @Test("同一本文の古い復旧証拠を選んでも新しいsequenceでremote確認まで完了する")
    func sameBodyRecoveryChoiceAdvancesSequenceBeforeAcknowledgement() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "accepted body",
            contentDigest: SyncContentDigest(content: "accepted body")
        )
        _ = try await editIntents.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        let checkpoint = DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID,
            sequence: 1,
            contentDigest: marker.contentDigest,
            containsLocalEditIntent: false
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)
        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)
        await editIntents.pauseNextPreservedRemoval()
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        #expect(await editIntents.waitUntilPreservedRemovalIsPaused())

        let staged = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(staged.marker?.mutationSequence == 2)
        #expect(staged.marker?.resolvesPreservedSequences == [1])

        await editIntents.resumePausedPreservedRemoval()
        for _ in 0 ..< 100 where state.deviceSyncLocalRecoveryReview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "accepted body")
        let completed = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(completed.marker == nil)
        #expect(completed.preservedMarkers.isEmpty)
    }

    @Test("新しいpackage checkpointは古いWALを次sequenceへ置換して再起動復旧する")
    func newerPackageCheckpointSupersedesStaleMarkerWithNewSequence() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let runtime = DeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let stale = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: replicaID,
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "stale body",
            contentDigest: SyncContentDigest(content: "stale body")
        )
        _ = try await editIntents.save(
            stale,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        let checkpoint = DeviceSyncPackageCheckpoint(
            protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID,
            sequence: 2,
            contentDigest: SyncContentDigest(content: "accepted body"),
            containsLocalEditIntent: true
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)
        let seeded = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID
        )
        #expect(seeded.marker == stale)
        #expect(seeded.committedPackage == checkpoint)
        #expect(state.deviceSyncPreparationTask == nil)

        await state.prepareDeviceSync(for: lookup)
        for _ in 0 ..< 100 {
            if await server.currentHead(
                for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
            ) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(state.document.episode(episodeID)?.episode.content == "accepted body")
        #expect(state.deviceSyncAllowsEditing(for: lookup))
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "accepted body")
        let completed = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID
        )
        #expect(completed.marker == nil)
        #expect(completed.committedPackage?.containsLocalEditIntent == false)
    }

    @Test("古いremote確認は同本文へ戻った新しいWALを削除しない")
    func staleRecoveryCompletionCannotDeleteNetZeroTailMarker() async throws {
        let fixture = makeFixture(content: "accepted body")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let workID = SyncWorkID()
        let runtimeReplicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: runtimeReplicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let evidence = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID,
            editorContentGeneration: lookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "accepted body"),
            acceptedPriorPackageDigests: nil,
            content: "preserved body",
            contentDigest: SyncContentDigest(content: "preserved body")
        )
        _ = try await editIntents.save(
            evidence,
            baselinePackageDigest: SyncContentDigest(content: "accepted body")
        )
        await state.prepareDeviceSync(for: lookup)
        let review = try #require(state.deviceSyncLocalRecoveryReview)

        await editIntents.pauseNextPreservedRemoval()
        await state.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        #expect(await editIntents.waitUntilPreservedRemovalIsPaused())

        let tailLookup = try #require(state.currentDeviceSyncLookupIdentity)
        state.updateEpisodeContent(
            "temporary tail",
            for: episodeID,
            in: tailLookup.chapterID,
            expectedSession: tailLookup.documentSession,
            expectedEditorContentGeneration: tailLookup.editorContentGeneration
        )
        state.updateEpisodeContent(
            "accepted body",
            for: episodeID,
            in: tailLookup.chapterID,
            expectedSession: tailLookup.documentSession,
            expectedEditorContentGeneration: tailLookup.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        #expect(await state.flushPendingDeviceSyncEditIntents())
        state.saveCoordinator.markDirty()
        #expect(await state.saveCoordinator.saveNow())
        let identity = try #require(state.activeDeviceSyncIdentity)
        let client = try #require(state.deviceSyncClient(for: identity))
        let tailSnapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        let tailMarker = try #require(tailSnapshot.marker)
        let tailReceipt = try await client.coordinator.recordLocalEdit(
            "accepted body",
            createdAt: runtime.now()
        )
        await state.markDeviceSyncLocalEditSavedIfCurrent(
            tailReceipt,
            content: "accepted body",
            expectedIdentity: identity,
            acknowledgedMutationSequence: tailMarker.mutationSequence
        )
        state.applyDeviceSyncState(tailReceipt.state, client: client, expectedIdentity: identity)

        await editIntents.resumePausedPreservedRemoval()
        for _ in 0 ..< 20 where state.deviceSyncState != .needsReview {
            await Task.yield()
        }
        var retained = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        #expect(retained.preservedMarkers == [evidence])
        #expect(retained.marker == tailMarker)
        #expect(state.deviceSyncLocalRecoveryReview != nil)

        let synchronized = try await client.coordinator.synchronizeLocalFirst(
            expiresAt: runtime.leaseExpiration(),
            createdAt: runtime.now()
        )
        #expect(await state.completeDeviceSyncLocalRecoveryReviewIfConfirmed(
            state: synchronized,
            client: client,
            identity: identity,
            runtime: runtime
        ))
        retained = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        #expect(retained.marker == nil)
        #expect(retained.preservedMarkers.isEmpty)
    }

    @Test("private copyの事前採用検査失敗は元sessionとURLを変えない")
    func rejectedPrivateCopyDoesNotAdoptDestination() async {
        let fixture = makeFixture(content: "source")
        let destination = packageURL("rejected-private-copy")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository)
        #expect(await state.openDocument(at: fixture.url))
        let originalSession = state.documentSessionToken
        let originalURL = state.documentURL

        let result = await state.saveDocumentResult(
            as: destination,
            expectedSession: originalSession,
            preAdoptionValidation: { _ in
                throw DeviceSyncAppRepositoryError.rejectedPrivateCopy
            }
        )

        #expect(result == .failedBeforeSwitch)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.documentURL == originalURL)
        #expect(state.document.episode(fixture.document.chapters[0].episodes[0].id)?.episode.content == "source")
    }

    @Test("private working-copy rootはsymlinkとroot identity差し替えを拒否する")
    func privateWorkingCopyRootRejectsSymlinksAndReplacement() throws {
        let fileManager = FileManager.default
        let applicationSupport = try #require(
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let sandbox = applicationSupport
            .appendingPathComponent("FUMINIWA-Private-Root-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let realParent = sandbox.appendingPathComponent("real", isDirectory: true)
        try fileManager.createDirectory(at: realParent, withIntermediateDirectories: true)
        let alias = sandbox.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: realParent)
        var rejectedAncestorSymlink = false
        do {
            _ = try DeviceSyncPrivateWorkingCopyRoot.prepare(
                alias.appendingPathComponent("root", isDirectory: true),
                fileManager: fileManager
            )
        } catch {
            rejectedAncestorSymlink = true
        }
        #expect(rejectedAncestorSymlink)

        let actualRoot = sandbox.appendingPathComponent("actual-root", isDirectory: true)
        try fileManager.createDirectory(at: actualRoot, withIntermediateDirectories: false)
        let finalRootLink = sandbox.appendingPathComponent("root-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: finalRootLink, withDestinationURL: actualRoot)
        var rejectedFinalSymlink = false
        do {
            _ = try DeviceSyncPrivateWorkingCopyRoot.prepare(
                finalRootLink,
                fileManager: fileManager
            )
        } catch {
            rejectedFinalSymlink = true
        }
        #expect(rejectedFinalSymlink)

        let rootURL = sandbox.appendingPathComponent("fixed", isDirectory: true)
        let root = try DeviceSyncPrivateWorkingCopyRoot.prepare(rootURL, fileManager: fileManager)
        let packageURL = rootURL.appendingPathComponent("copy.novelpkg", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        try root.validateCopiedPackage(at: packageURL)

        let movedRoot = sandbox.appendingPathComponent("moved", isDirectory: true)
        try fileManager.moveItem(at: rootURL, to: movedRoot)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
        var rejectedReplacement = false
        do {
            try root.validateFixedRoot()
        } catch {
            rejectedReplacement = true
        }
        #expect(rejectedReplacement)
    }

    @Test("production sync準備失敗は外部openや新規作成で迂回できない")
    func deviceSyncStartupFailureIsSticky() async {
        let repository = DeviceSyncAppRepository()
        let state = makeState(repository: repository)
        let originalDocument = state.document
        let originalSession = state.documentSessionToken

        state.failStartupForDeviceSyncSafety()

        guard case let .recovery(context) = state.startupState else {
            Issue.record("Device Syncの安全停止がRecoveryになっていません。")
            return
        }
        #expect(context.reason == .deviceSyncSafetyUnavailable)
        #expect(!state.permitsDocumentInteraction)
        #expect(!state.permitsDocumentChoice)
        #expect(!state.permitsLongRunningDocumentOperation)
        #expect(await !(state.openExternalDocument(at: packageURL("blocked-open"))))
        #expect(await !(state.createNewDocument(expectedSession: originalSession)))
        await state.retryStartup()
        #expect(state.document == originalDocument)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.deviceSyncStartupFailedSafely)
    }

    @Test("遅い旧binding lookupは新しい話の同期状態を上書きしない")
    func staleBindingLookupCannotOverwriteNewSelection() async throws {
        let firstEpisode = Episode(content: "first")
        let secondEpisode = Episode(content: "second")
        let document = NovelDocument(
            title: "lookup race",
            chapters: [
                Chapter(title: "first", episodes: [firstEpisode]),
                Chapter(title: "second", episodes: [secondEpisode])
            ]
        )
        let url = packageURL("lookup-race")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let resolver = DelayedDeviceSyncBindingResolver()
        let server = InMemoryEpisodeSyncServer()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { session, _ in
                await resolver.resolve(session)
            }
        )
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: url))
        let staleLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let staleTask = Task { @MainActor in
            await state.prepareDeviceSync(for: staleLookup)
        }
        try #require(await resolver.waitUntilFirstLookupIsPaused())

        let secondChapter = document.chapters[1]
        state.selectChapter(secondChapter.id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let currentTask = Task { @MainActor in
            await state.prepareDeviceSync(for: currentLookup)
        }
        for _ in 0 ..< 100 {
            if state.deviceSyncAllowsEditing(for: currentLookup) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.deviceSyncAllowsEditing(for: currentLookup))
        #expect(await resolver.observedLookupCount() == 2)

        try await resolver.resumeFirstLookup(
            with: makeResolution(
                document: document,
                localWorkingCopyID: LocalWorkingCopyID(),
                workID: SyncWorkID(),
                journal: InMemoryEpisodeSyncJournal()
            )
        )
        await staleTask.value
        await currentTask.value

        #expect(state.currentDeviceSyncLookupIdentity == currentLookup)
        #expect(state.resolvedDeviceSyncLookupIdentity == currentLookup)
        #expect(state.activeDeviceSyncIdentity == nil)
        #expect(state.deviceSyncState == .unconfigured)
    }

    @Test("旧話のWAL隔離完了は新しい話の本文と復旧状態を上書きしない")
    func stalePreservedMarkerCompletionCannotOverwriteNewSelection() async throws {
        let firstEpisode = Episode(content: "old package")
        let secondEpisode = Episode(content: "new package")
        let document = NovelDocument(
            title: "stale local recovery",
            chapters: [
                Chapter(title: "old", episodes: [firstEpisode]),
                Chapter(title: "new", episodes: [secondEpisode])
            ]
        )
        let url = packageURL("stale-local-recovery")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let store = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let server = InMemoryEpisodeSyncServer()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in nil },
            editIntentStore: store
        )
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: url))
        let staleLookup = try #require(state.currentDeviceSyncLookupIdentity)
        let marker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: staleLookup.documentSession),
            documentID: staleLookup.documentSession.documentID,
            episodeID: firstEpisode.id,
            editorContentGeneration: staleLookup.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: SyncContentDigest(content: "old package"),
            acceptedPriorPackageDigests: [SyncContentDigest(content: "old package")],
            content: "old recovered branch",
            contentDigest: SyncContentDigest(content: "old recovered branch")
        )
        _ = try await store.save(
            marker,
            baselinePackageDigest: SyncContentDigest(content: "old package")
        )
        await store.pauseNextPreservation()
        let stalePreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: staleLookup)
        }
        #expect(await store.waitUntilPreservationIsPaused())

        state.selectChapter(document.chapters[1].id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: currentLookup)
        #expect(state.deviceSyncAllowsEditing(for: currentLookup))
        state.updateEpisodeContent(
            "new edited body",
            for: secondEpisode.id,
            in: document.chapters[1].id,
            expectedSession: currentLookup.documentSession,
            expectedEditorContentGeneration: currentLookup.editorContentGeneration
        )
        #expect(await state.saveNow())

        await store.resumePausedPreservation()
        await stalePreparation.value

        let oldSnapshot = try await store.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(oldSnapshot.marker == nil)
        #expect(oldSnapshot.preservedMarkers == [marker])
        #expect(state.document.episode(secondEpisode.id)?.episode.content == "new edited body")
        #expect(state.currentDeviceSyncLookupIdentity?.episodeID == secondEpisode.id)
        #expect(state.deviceSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncState == .unconfigured)
        #expect(await server.snapshotFetchInvocationCount() == 0)
    }

    @Test("旧話のpackage-only完了は新しい話の保存状態を上書きしない")
    func stalePackageOnlyCompletionCannotOverwriteNewSelection() async throws {
        let firstEpisode = Episode(content: "old local")
        let secondEpisode = Episode(content: "new local")
        let document = NovelDocument(
            title: "stale package only",
            chapters: [
                Chapter(title: "old", episodes: [firstEpisode]),
                Chapter(title: "new", episodes: [secondEpisode])
            ]
        )
        let url = packageURL("stale-package-only")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let store = PausablePreservedRemovalDeviceSyncEditIntentStore()
        let server = InMemoryEpisodeSyncServer()
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in nil },
                editIntentStore: store
            )
        )
        #expect(await state.openDocument(at: url))
        let staleLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await store.pauseReconcilePreparedPackage(episodeID: firstEpisode.id, invocation: 2)
        let stalePreparation = Task { @MainActor in
            await state.prepareDeviceSync(for: staleLookup)
        }
        #expect(await store.waitUntilReconcileIsPaused())

        state.selectChapter(document.chapters[1].id)
        let currentLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: currentLookup)
        #expect(state.deviceSyncAllowsEditing(for: currentLookup))
        state.updateEpisodeContent(
            "new package-only edit",
            for: secondEpisode.id,
            in: document.chapters[1].id,
            expectedSession: currentLookup.documentSession,
            expectedEditorContentGeneration: currentLookup.editorContentGeneration
        )
        #expect(await state.saveNow())
        let stateBeforeResume = state.deviceSyncState
        let durabilityBeforeResume = state.deviceSyncLocalDurabilityState

        await store.resumePausedReconcile()
        await stalePreparation.value

        #expect(state.document.episode(secondEpisode.id)?.episode.content == "new package-only edit")
        #expect(state.currentDeviceSyncLookupIdentity?.episodeID == secondEpisode.id)
        #expect(state.deviceSyncLocalRecoveryReview == nil)
        #expect(state.deviceSyncState == stateBeforeResume)
        #expect(state.deviceSyncLocalDurabilityState == durabilityBeforeResume)
        #expect(await server.snapshotFetchInvocationCount() == 0)
    }

    @Test("同じ話の同期準備は一つのbinding lookupへ合流する")
    func duplicatePreparationJoinsSingleBindingLookup() async throws {
        let fixture = makeFixture(content: "single flight")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolver = DelayedDeviceSyncBindingResolver()
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                binding: { session, _ in
                    await resolver.resolve(session)
                }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)

        let first = Task { @MainActor in
            await state.prepareDeviceSync(for: lookup)
        }
        try #require(await resolver.waitUntilFirstLookupIsPaused())
        let second = Task { @MainActor in
            await state.prepareDeviceSync(for: lookup)
        }
        await Task.yield()

        #expect(await resolver.observedLookupCount() == 1)
        await resolver.resumeFirstLookup(with: nil)
        await first.value
        await second.value

        #expect(await resolver.observedLookupCount() == 1)
        #expect(state.deviceSyncState == .unconfigured)
        #expect(state.resolvedDeviceSyncLookupIdentity == lookup)
    }

    @Test("local-only準備中のready通知は同じEditorを再解決して保留本文を送る")
    func readySignalDuringLocalOnlyPreparationIsRevalidated() async throws {
        let fixture = makeFixture(content: "local base")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(localWorkingCopyID: localWorkingCopyID, workID: workID)
        let descriptor = try SyncWorkDescriptor(
            workID: workID,
            sourceDocumentID: fixture.document.id,
            structureDigest: SyncWorkStructureDigest(chapters: fixture.document.chapters),
            title: fixture.document.title
        )
        let localOnly = DeviceSyncBindingResolution(
            binding: binding,
            descriptor: nil,
            journal: journal,
            allowedEpisodeIDs: [episodeID]
        )
        let remoteReady = DeviceSyncBindingResolution(
            binding: binding,
            descriptor: descriptor,
            journal: journal,
            allowedEpisodeIDs: [episodeID]
        )
        let resolver = LocalFirstBindingSequenceResolver(initial: localOnly, subsequent: remoteReady)
        let signal = AsyncStream<Void>.makeStream()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in try await resolver.resolve() },
                remoteChangeSignals: signal.stream
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        let preparation = Task { @MainActor in
            await state.prepareDeviceSync(for: lookup)
        }
        try #require(await resolver.waitUntilInitialLookupIsPaused())

        state.updateEpisodeContent(
            "pending while local only",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        signal.continuation.yield(())
        await resolver.resumeInitialLookup()
        await preparation.value
        for _ in 0 ..< 100 {
            if await server.currentHead(for: EpisodeSyncKey(workID: workID, episodeID: episodeID))?.content
                == "pending while local only" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        signal.continuation.finish()

        #expect(await resolver.lookupCount() >= 2)
        #expect(await server.currentHead(
            for: EpisodeSyncKey(workID: workID, episodeID: episodeID)
        )?.content == "pending while local only")
        #expect(state.selectedEpisodeID == episodeID)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("新WAL失敗後もpackage本文を保存し古いWALでは巻き戻さない")
    func failedLatestIntentCannotRollBackSavedPackage() async throws {
        let fixture = makeFixture(content: "初期本文")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = FailingDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let runtime = DeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: { _, _ in resolution },
            editIntentStore: editIntents
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(repository: repository, runtime: runtime)
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let identity = try #require(state.activeDeviceSyncIdentity)
        let staleMarker = DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: state.documentSessionToken),
            documentID: fixture.document.id,
            episodeID: episodeID,
            editorContentGeneration: state.editorContentGeneration,
            mutationSequence: 10,
            createdAt: Date(timeIntervalSince1970: 10),
            replicaID: replicaID,
            localWorkingCopyID: identity.localWorkingCopyID,
            workID: identity.syncKey.workID,
            baseContentDigest: SyncContentDigest(content: fixture.document.episode(episodeID)?.episode.content ?? ""),
            acceptedPriorPackageDigests: [
                SyncContentDigest(content: fixture.document.episode(episodeID)?.episode.content ?? "")
            ],
            content: "古い復旧証拠",
            contentDigest: SyncContentDigest(content: "古い復旧証拠")
        )
        await editIntents.seed(staleMarker)
        await editIntents.failAllSaves()
        state.updateEpisodeContent(
            "packageが保持する新本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        #expect(await state.flushDeviceSyncForBackground())
        let saved = try await repository.load(from: fixture.url)
        #expect(saved.episode(episodeID)?.episode.content == "packageが保持する新本文")
        #expect(state.deviceSyncLocalDurabilityState == .failed)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: fixture.url))
        try await relaunched.prepareDeviceSync(for: #require(relaunched.currentDeviceSyncLookupIdentity))
        #expect(relaunched.document.episode(episodeID)?.episode.content == "packageが保持する新本文")
        #expect(relaunched.deviceSyncLocalDurabilityState == .failed)
        #expect(await editIntents.markers() == [staleMarker])
    }

    @Test("入力時に永続化済みのWALをpublishが再利用してjournalとremoteまで確定する")
    func publishReusesPersistedInputIntent() async throws {
        let fixture = makeFixture(content: "initial")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = InMemoryDeviceSyncEditIntentStore()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution },
                editIntentStore: editIntents
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        state.updateEpisodeContent(
            "latest input",
            for: episodeID,
            in: chapterID,
            expectedSession: lookup.documentSession,
            expectedEditorContentGeneration: lookup.editorContentGeneration
        )
        #expect(await state.flushPendingDeviceSyncEditIntents())
        let persisted = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: state.deviceSyncWorkingCopyIdentity(for: lookup.documentSession),
            documentID: lookup.documentSession.documentID,
            episodeID: episodeID
        )
        let persistedMarker = try #require(persisted.marker)
        #expect(persistedMarker.content == "latest input")

        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        await state.publishDeviceSyncDraft(content: "latest input", expectedLookup: lookup)

        let key = EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        let package = try await repository.load(from: fixture.url)
        let record = try #require(await journal.storedRecord(for: key))
        let settled = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: persistedMarker.workingCopyIdentity,
            documentID: persistedMarker.documentID,
            episodeID: persistedMarker.episodeID
        )
        #expect(package.episode(episodeID)?.episode.content == "latest input")
        #expect(record.localHead.content == "latest input")
        #expect(await server.currentHead(for: key)?.content == "latest input")
        #expect(settled.marker == nil)
        #expect(state.deviceSyncLocalDurabilityState == .saved)
    }

    @Test("WAL一時失敗は追加入力なしの次回保存でjournalまで再試行する")
    func transientIntentFailureRetriesLatestBodyOnNextSave() async throws {
        let fixture = makeFixture(content: "初期本文")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = FailingDeviceSyncEditIntentStore()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution },
                editIntentStore: editIntents
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        // The immediate WAL worker and the debounced draft retry both fail.
        // The following background save is therefore the first successful retry.
        await editIntents.failNextSaves(2)
        state.updateEpisodeContent(
            "一度失敗した最新本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        await state.deviceSyncDraftTask?.value
        #expect(state.deviceSyncLocalDurabilityState == .failed)

        #expect(await state.flushDeviceSyncForBackground())
        let package = try await repository.load(from: fixture.url)
        let record = try #require(await journal.storedRecord(
            for: EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        ))
        #expect(package.episode(episodeID)?.episode.content == "一度失敗した最新本文")
        #expect(record.localHead.content == "一度失敗した最新本文")
        #expect(await editIntents.markers().isEmpty)
        #expect(state.deviceSyncLocalDurabilityState == .saved)
    }

    @Test("同じ話の重複refreshは一つのremote検査へ合流する")
    func duplicateRefreshJoinsSingleRemoteInspection() async throws {
        let fixture = makeFixture(content: "R0")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let server = InMemoryEpisodeSyncServer()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
        )
        let resolver = PausableCountingDeviceSyncBindingResolver(resolution: resolution)
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in await resolver.resolve() }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        try await state.prepareDeviceSync(for: lookup)
        state.updateEpisodeContent(
            "R1",
            for: episodeID,
            in: chapterID,
            expectedSession: lookup.documentSession,
            expectedEditorContentGeneration: lookup.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        await state.publishDeviceSyncDraft(content: "R1", expectedLookup: lookup)
        #expect(state.deviceSyncState == .writer)

        let initialLookupCount = await resolver.lookupCount()
        await resolver.pauseNextLookup()
        let first = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        try #require(await resolver.waitUntilLookupIsPaused())
        let second = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        await Task.yield()

        #expect(await resolver.lookupCount() == initialLookupCount + 1)
        await resolver.resumePausedLookup()
        await first.value
        await second.value

        #expect(await resolver.lookupCount() == initialLookupCount + 1)
        #expect(state.deviceSyncState == .writer)
    }

    @Test("旧claim応答は離脱後に再取得したauthorityを解放しない")
    func staleClaimCannotReleaseAuthorityAfterReselection() async throws {
        let fixture = makeFixture(content: "shared")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let workID = SyncWorkID()
        let server = InMemoryEpisodeSyncServer()
        let firstRepository = DeviceSyncAppRepository()
        let secondRepository = DeviceSyncAppRepository()
        let firstURL = packageURL("claim-race-first")
        let secondURL = packageURL("claim-race-second")
        await firstRepository.seed(fixture.document, at: firstURL)
        await secondRepository.seed(fixture.document, at: secondURL)
        let firstResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let secondResolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let firstState = makeState(
            repository: firstRepository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in firstResolution }
            )
        )
        let secondReplicaID = SyncReplicaID()
        let secondEditIntents = InMemoryDeviceSyncEditIntentStore()
        let secondState = makeState(
            repository: secondRepository,
            runtime: DeviceSyncRuntime(
                replicaID: secondReplicaID,
                transport: server,
                binding: { _, _ in secondResolution },
                editIntentStore: secondEditIntents
            )
        )
        #expect(await firstState.openDocument(at: firstURL))
        let firstLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        try await firstState.prepareDeviceSync(for: firstLookup)
        for content in ["temporary first edit", "shared"] {
            firstState.updateEpisodeContent(
                content,
                for: episodeID,
                in: chapterID,
                expectedSession: firstLookup.documentSession,
                expectedEditorContentGeneration: firstLookup.editorContentGeneration
            )
        }
        firstState.deviceSyncDraftTask?.cancel()
        firstState.deviceSyncDraftTask = nil
        await firstState.publishDeviceSyncDraft(content: "shared", expectedLookup: firstLookup)
        #expect(await secondState.openDocument(at: secondURL))
        let secondLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        try await secondState.prepareDeviceSync(for: secondLookup)
        #expect(firstState.deviceSyncState == .writer)
        #expect(secondState.deviceSyncState == .readOnly)

        let firstIdentity = try #require(firstState.activeDeviceSyncIdentity)
        let firstClient = try #require(firstState.deviceSyncClient(for: firstIdentity))
        _ = try await firstClient.coordinator.releaseEditingAuthority()

        await server.pauseNextClaim()
        secondState.updateEpisodeContent(
            "second local edit",
            for: episodeID,
            in: chapterID,
            expectedSession: secondLookup.documentSession,
            expectedEditorContentGeneration: secondLookup.editorContentGeneration
        )
        secondState.deviceSyncDraftTask?.cancel()
        secondState.deviceSyncDraftTask = nil
        let stalePublish = Task { @MainActor in
            await secondState.publishDeviceSyncDraft(content: "second local edit", expectedLookup: secondLookup)
        }
        let reachedClaim = await waitUntilDeviceSyncClaimIsPaused(on: server)
        try #require(reachedClaim)

        #expect(await secondState.selectProjectSectionAfterDeviceSyncDeparture(.settings))
        #expect(await secondState.selectProjectSectionAfterDeviceSyncDeparture(.structure))
        let reselectionLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        let reselection = Task { @MainActor in
            await secondState.prepareDeviceSync(for: reselectionLookup)
        }
        await Task.yield()
        #expect(await server.currentLease(for: firstIdentity.syncKey) == nil)

        await server.resumePausedClaim()
        await stalePublish.value
        await reselection.value

        let currentIdentity = try #require(secondState.activeDeviceSyncIdentity)
        let currentClient = try #require(secondState.deviceSyncClient(for: currentIdentity))
        let didSettle = await waitUntilDeviceSyncSettles(secondState)
        let lease = try #require(await server.currentLease(for: currentIdentity.syncKey))
        let coordinatorState = await currentClient.coordinator.state
        try #require(didSettle)
        let coordinatorContext = try #require({
            if case let .upToDate(context) = coordinatorState {
                return context
            }
            return nil
        }())
        #expect(secondState.deviceSyncState == .writer)
        #expect(secondState.deviceSyncTransferState == .upToDate)
        #expect(coordinatorContext.pendingRevisionCount == 0)
        #expect(coordinatorContext.remoteConfirmation == .confirmed)
        #expect(coordinatorContext.localHead.content == "second local edit")
        #expect(await server.currentHead(for: currentIdentity.syncKey)?.content == "second local edit")
        // D-060では閲覧・再選択だけでは新しいauthorityをclaimしない。同じ
        // working copy/clientに属する保留local editは、停止していた元claimを
        // 完了してよく、そのepochを余分に進めない。
        #expect(lease.authority.epoch == 2)
        #expect(lease.authority.holderReplicaID == secondReplicaID)
        #expect(lease.authority.holderSessionID == currentClient.sessionID)
    }

    @Test("同じ作品IDの別copyはURLごとの明示bindingなしに同期作品へ結合しない")
    func copiedDocumentWithSameDocumentIDRequiresIndependentBinding() async throws {
        let document = NovelDocument.newDocument(title: "copied")
        let firstURL = packageURL("bound-copy")
        let secondURL = packageURL("unbound-copy")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: firstURL)
        await repository.seed(document, at: secondURL)
        let localWorkingCopyID = LocalWorkingCopyID()
        let workID = SyncWorkID()
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: workID,
            journal: InMemoryEpisodeSyncJournal()
        )
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            binding: { session, _ in
                guard session.documentURL.standardizedFileURL == firstURL.standardizedFileURL else {
                    return nil
                }
                return resolution
            }
        )
        let state = makeState(repository: repository, runtime: runtime)

        #expect(await state.openDocument(at: firstURL))
        let firstLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: firstLookup)
        #expect(state.activeDeviceSyncIdentity?.localWorkingCopyID == localWorkingCopyID)

        #expect(await state.openDocument(at: secondURL))
        #expect(state.document.id == document.id)
        let secondLookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: secondLookup)

        #expect(state.documentSessionToken.documentURL == secondURL.standardizedFileURL)
        #expect(state.activeDeviceSyncIdentity == nil)
        #expect(state.deviceSyncState == .unconfigured)
    }

    @Test("設定画面はEditor未表示でも作品bindingを読み直す")
    func setupStatusRefreshFindsExistingBinding() async throws {
        let fixture = makeFixture(content: "bound")
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
        )
        let setup = DeviceSyncSetupRuntime(
            privateWorkingCopyDestination: { _ in nil },
            validatePrivateWorkingCopy: { _ in },
            candidates: { _, _, _ in [] },
            startNew: { _, _, _ in },
            bindExisting: { _, _, _, _, _ in }
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                binding: { _, _ in resolution },
                setup: setup
            )
        )
        #expect(await state.openDocument(at: fixture.url))

        await state.refreshDeviceSyncSetupStatus(expectedSession: state.documentSessionToken)

        #expect(state.deviceSyncSetupState == .configured)
    }

    @Test("同じremote workへ明示bindingした2 copyは別journalで同時にlocal編集できる")
    func twoBoundCopiesUseIndependentJournals() async throws {
        let chapterID = ChapterID()
        let episodeID = EpisodeID()
        let document = NovelDocument(
            title: "two copies",
            chapters: [
                Chapter(
                    id: chapterID,
                    title: "chapter",
                    episodes: [Episode(id: episodeID, content: "shared base")]
                )
            ]
        )
        let firstURL = packageURL("journal-copy-one")
        let secondURL = packageURL("journal-copy-two")
        let firstRepository = DeviceSyncAppRepository()
        let secondRepository = DeviceSyncAppRepository()
        await firstRepository.seed(document, at: firstURL)
        await secondRepository.seed(document, at: secondURL)
        let server = InMemoryEpisodeSyncServer()
        let workID = SyncWorkID()
        let firstJournal = InMemoryEpisodeSyncJournal()
        let secondJournal = InMemoryEpisodeSyncJournal()
        let firstResolution = try makeResolution(
            document: document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: firstJournal
        )
        let secondResolution = try makeResolution(
            document: document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: secondJournal
        )
        let firstState = makeState(
            repository: firstRepository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in firstResolution }
            )
        )
        let secondState = makeState(
            repository: secondRepository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in secondResolution }
            )
        )

        #expect(await firstState.openDocument(at: firstURL))
        let firstLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        try await firstState.prepareDeviceSync(for: firstLookup)
        #expect(await secondState.openDocument(at: secondURL))
        let secondLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        try await secondState.prepareDeviceSync(for: secondLookup)

        let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
        let firstRecord = try #require(await firstJournal.storedRecord(for: key))
        let secondRecord = try #require(await secondJournal.storedRecord(for: key))
        #expect(firstRecord.lease == nil)
        #expect(secondRecord.lease == nil)
        #expect(firstResolution.binding.localWorkingCopyID != secondResolution.binding.localWorkingCopyID)
        #expect(firstState.deviceSyncState == .readOnly)
        #expect(secondState.deviceSyncState == .readOnly)

        await server.setOnline(false)
        firstState.updateEpisodeContent(
            "first offline edit",
            for: episodeID,
            in: chapterID,
            expectedSession: firstLookup.documentSession,
            expectedEditorContentGeneration: firstLookup.editorContentGeneration
        )
        firstState.deviceSyncDraftTask?.cancel()
        firstState.deviceSyncDraftTask = nil
        await firstState.publishDeviceSyncDraft(content: "first offline edit", expectedLookup: firstLookup)

        secondState.updateEpisodeContent(
            "second offline edit",
            for: episodeID,
            in: chapterID,
            expectedSession: secondLookup.documentSession,
            expectedEditorContentGeneration: secondLookup.editorContentGeneration
        )
        secondState.deviceSyncDraftTask?.cancel()
        secondState.deviceSyncDraftTask = nil
        await secondState.publishDeviceSyncDraft(content: "second offline edit", expectedLookup: secondLookup)

        let firstEdited = try #require(await firstJournal.storedRecord(for: key))
        let secondEdited = try #require(await secondJournal.storedRecord(for: key))
        #expect(firstEdited.localHead.content == "first offline edit")
        #expect(secondEdited.localHead.content == "second offline edit")
        #expect(firstEdited.localWorkingCopyID == firstResolution.binding.localWorkingCopyID)
        #expect(secondEdited.localWorkingCopyID == secondResolution.binding.localWorkingCopyID)
        #expect(firstState.deviceSyncState == .offlineLocal)
        #expect(secondState.deviceSyncState == .offlineLocal)
        let firstEditedLookup = try #require(firstState.currentDeviceSyncLookupIdentity)
        let secondEditedLookup = try #require(secondState.currentDeviceSyncLookupIdentity)
        #expect(firstState.deviceSyncAllowsEditing(for: firstEditedLookup))
        #expect(secondState.deviceSyncAllowsEditing(for: secondEditedLookup))
        #expect(await server.currentHead(for: key) == nil)
    }

    @Test("明示binding後の構造変更でも既存話は同期を継続する")
    func existingEpisodeSurvivesLaterStructureChange() async throws {
        let fixture = makeFixture(content: "local")
        let incompatible = NovelDocument(
            id: fixture.document.id,
            title: fixture.document.title,
            chapters: fixture.document.chapters + [Chapter(title: "new chapter", episodes: [])]
        )
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: incompatible,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: InMemoryEpisodeSyncJournal()
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: InMemoryEpisodeSyncServer(),
                binding: { _, _ in resolution }
            )
        )

        #expect(await state.openDocument(at: fixture.url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)

        #expect(state.deviceSyncState == .readOnly)
        #expect(state.activeDeviceSyncIdentity?.episodeID == fixture.document.chapters[0].episodes[0].id)
        #expect(state.deviceSyncAllowsEditing(for: lookup))

        let episodeID = fixture.document.chapters[0].episodes[0].id
        let chapterID = fixture.document.chapters[0].id
        state.updateEpisodeContent(
            "local after structure change",
            for: episodeID,
            in: chapterID,
            expectedSession: lookup.documentSession,
            expectedEditorContentGeneration: lookup.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        await state.publishDeviceSyncDraft(content: "local after structure change", expectedLookup: lookup)

        #expect(state.deviceSyncState == .writer)
    }

    @Test("旧sealed再送後に残る最新tailも入力停止中に送信する")
    func publishRetriesTailAfterInterruptedSealedBatch() async throws {
        let fixture = makeFixture(content: "initial")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let workID = SyncWorkID()
        let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID,
            journal: journal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        #expect(state.deviceSyncState == .readOnly)

        await server.cancelNextPublish()
        state.updateEpisodeContent(
            "first sealed",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        await state.deviceSyncDraftTask?.value
        let interrupted = try #require(await journal.storedRecord(for: key))
        #expect(interrupted.sealedPublish != nil)

        state.updateEpisodeContent(
            "latest tail",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        let latestDraft = try #require(state.deviceSyncDraftTask)
        await latestDraft.value

        let remote = try #require(await server.currentHead(for: key))
        let settled = try #require(await journal.storedRecord(for: key))
        #expect(remote.content == "latest tail")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(settled.sealedPublish == nil)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("通信が停止中でもbackground保存は待たずに最新IME本文をpackageへ残す")
    func backgroundFlushDoesNotWaitForPausedPublish() async throws {
        let fixture = makeFixture(content: "initial")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let journal = InMemoryEpisodeSyncJournal()
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let committedText = "通信中にIMEで確定した最新本文"
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            ),
            activeCommittedTextCapture: { .captured(committedText) }
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        #expect(state.deviceSyncState == .readOnly)

        await server.pauseNextPublish()
        state.updateEpisodeContent(
            "送信中の旧本文",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        try #require(await waitUntilDeviceSyncPublishIsPaused(on: server))

        let flush = Task { @MainActor in
            await state.flushDeviceSyncForBackground()
        }
        try await Task.sleep(for: .milliseconds(100))
        let savedBeforeNetworkResumed = try await repository.load(from: fixture.url)
        #expect(savedBeforeNetworkResumed.episode(episodeID)?.episode.content == committedText)
        let key = EpisodeSyncKey(workID: resolution.binding.workID, episodeID: episodeID)
        let durableTail = try #require(await journal.storedRecord(for: key))
        #expect(durableTail.localHead.content == committedText)
        #expect(durableTail.pendingRevisions.contains { $0.content == committedText })

        await server.resumePausedPublish()
        #expect(await flush.value)
        try await Task.sleep(for: .milliseconds(100))
        let retainedTail = try #require(await journal.storedRecord(for: durableTail.key))
        #expect(retainedTail.localHead.content == committedText)
    }

    @Test("packageだけ先行した本文はauthority再取得時にjournalとremoteへ反映する")
    func verifiedAuthorityReplaysPackageAheadContent() async throws {
        let fixture = makeFixture(content: "R0")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let identity = try #require(state.activeDeviceSyncIdentity)
        let client = try #require(state.deviceSyncClient(for: identity))

        state.updateEpisodeContent(
            "X package ahead",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        state.deviceSyncDraftTask?.cancel()
        state.deviceSyncDraftTask = nil
        #expect(await state.saveNow())
        let before = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(before.localHead.content == "R0")

        _ = try await client.coordinator.releaseEditingAuthority()
        await state.refreshSelectedEpisodeDeviceSync()

        let remote = try #require(await server.currentHead(for: identity.syncKey))
        let settled = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(remote.content == "X package ahead")
        #expect(settled.localHead.content == "X package ahead")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(state.deviceSyncState == .writer)
        #expect(state.deviceSyncTransferState == .upToDate)
    }

    @Test("停止中の古いfence応答は新しいdraft publishを巻き戻さない")
    func staleFenceResponseCannotRollBackDraftPublish() async throws {
        let fixture = makeFixture(content: "R0")
        let episodeID = try #require(fixture.document.chapters.first?.episodes.first?.id)
        let chapterID = try #require(fixture.document.chapters.first?.id)
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let repository = DeviceSyncAppRepository()
        await repository.seed(fixture.document, at: fixture.url)
        let resolution = try makeResolution(
            document: fixture.document,
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: SyncWorkID(),
            journal: journal
        )
        let state = makeState(
            repository: repository,
            runtime: DeviceSyncRuntime(
                replicaID: SyncReplicaID(),
                transport: server,
                binding: { _, _ in resolution }
            )
        )
        #expect(await state.openDocument(at: fixture.url))
        try await state.prepareDeviceSync(for: #require(state.currentDeviceSyncLookupIdentity))
        let identity = try #require(state.activeDeviceSyncIdentity)

        await server.pauseNextSnapshotResponseAfterCapture()
        let refresh = Task { @MainActor in
            await state.refreshSelectedEpisodeDeviceSync()
        }
        try #require(await waitUntilDeviceSyncSnapshotResponseIsPaused(on: server))

        state.updateEpisodeContent(
            "R1",
            for: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken,
            expectedEditorContentGeneration: state.editorContentGeneration
        )
        let draft = try #require(state.deviceSyncDraftTask)
        for _ in 0 ..< 100 {
            if await journal.storedRecord(for: identity.syncKey)?.localHead.content == "R1" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let durableTail = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(durableTail.localHead.content == "R1")
        // clean openはremoteへ基準本文をpublishしない。停止中snapshotがnilでも、
        // その後の明示編集R1はjournalから安全に送信できる。
        #expect(await server.currentHead(for: identity.syncKey) == nil)

        await server.resumePausedSnapshotResponse()
        await refresh.value
        await draft.value

        let settled = try #require(await journal.storedRecord(for: identity.syncKey))
        #expect(await server.currentHead(for: identity.syncKey)?.content == "R1")
        #expect(settled.localHead.content == "R1")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(state.document.episode(episodeID)?.episode.content == "R1")
        #expect(state.deviceSyncState == .writer)
    }

    @Test("競合choiceのpackage・journal確定後に終了しても再起動が自動publish・cleanupする")
    func materializedConflictChoiceResumesAfterRelaunchBeforeRemotePublish() async throws {
        let episodeID = EpisodeID()
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let now = Date(timeIntervalSince1970: 9000)
        let remoteWriter = EpisodeSyncCoordinator(
            key: key,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        _ = try await remoteWriter.link(
            localContent: "remote body",
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        let remote = try #require(await server.currentHead(for: key))
        let localWorkingCopyID = LocalWorkingCopyID()
        let local = try EpisodeRevision(
            key: key,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: "local accepted body",
            clientCreatedAt: now.addingTimeInterval(1)
        )
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)
        let journal = InMemoryEpisodeSyncJournal()
        try await journal.save(EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            branchID: local.branchID,
            lastKnownRemoteHead: remote,
            localHead: local,
            pendingRevisions: [local],
            conflict: conflict,
            mode: .forcedFork
        ))
        let chapterID = ChapterID()
        let document = NovelDocument(
            title: "generic conflict recovery",
            chapters: [Chapter(
                id: chapterID,
                title: "chapter",
                episodes: [Episode(id: episodeID, content: local.content)]
            )]
        )
        let url = packageURL("generic-conflict-choice-relaunch")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: key.workID,
            journal: journal
        )
        let mergeRecoveryStore = InMemoryDeviceSyncMergeRecoveryStore()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in resolution },
            mergeRecoveryStore: mergeRecoveryStore,
            now: { now.addingTimeInterval(10) },
            leaseDuration: 600
        )
        let firstState = makeState(
            repository: repository,
            runtime: runtime,
            activeCommittedTextCapture: { .captured(local.content) }
        )
        #expect(await firstState.openDocument(at: url))
        try await firstState.prepareDeviceSync(for: #require(firstState.currentDeviceSyncLookupIdentity))
        let presented = try #require(firstState.deviceSyncConflict)
        #expect(presented == conflict)
        await server.pauseNextPublish()
        await firstState.resolveDeviceSyncConflict(using: .keepLocal, expectedConflict: presented)
        try #require(await waitUntilDeviceSyncPublishIsPaused(on: server))
        let interruptedIdentity = try #require(firstState.activeDeviceSyncIdentity)
        let interruptedClient = try #require(firstState.deviceSyncClient(for: interruptedIdentity))
        let materialized = try #require(await journal.storedRecord(for: key))
        let chosen = try #require(materialized.stagedConflictResolution)
        #expect(chosen.content == local.content)
        #expect(Set(chosen.parentRevisionIDs) == Set([local.revisionID, remote.revisionID]))
        #expect(materialized.conflict == nil)
        #expect(materialized.conflictResolutionRecovery?.chosenRevision == chosen)
        let saved = try await repository.load(from: url)
        #expect(saved.episode(episodeID)?.episode.content == local.content)
        #expect(await server.currentHead(for: key) == remote)
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)
        // packageとjournalの確定直後にprocessが終了し、旧publishはcommitしない。
        await server.setOnline(false)
        await server.resumePausedPublish()
        try #require(await waitUntilDeviceSyncCoordinatorStopsSynchronizing(interruptedClient.coordinator))
        #expect(await server.currentHead(for: key) == remote)
        await server.setOnline(true)

        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: url))
        try await relaunched.prepareDeviceSync(for: #require(relaunched.currentDeviceSyncLookupIdentity))
        var didRecover = false
        for _ in 0 ..< 2000 {
            let head = await server.currentHead(for: key)
            let stored = await journal.storedRecord(for: key)
            if head?.revisionID == chosen.revisionID,
               stored?.localHead.revisionID == chosen.revisionID,
               stored?.pendingRevisions.isEmpty == true,
               stored?.stagedConflictResolution == nil,
               stored?.conflictResolutionRecovery == nil {
                didRecover = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(didRecover)
        let recoveredHead = try #require(await server.currentHead(for: key))
        #expect(recoveredHead.content == local.content)
        #expect(Set(recoveredHead.parentRevisionIDs) == Set([local.revisionID, remote.revisionID]))
        #expect(relaunched.document.episode(episodeID)?.episode.content == local.content)
        #expect(relaunched.deviceSyncConflict == nil)
        #expect(relaunched.pendingDeviceSyncConflictResolution == nil)
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)
    }

    @Test("競合中の追加localとremote raceを保持した2-parent mergeだけを公開する")
    func conflictForceRacePreservesLatestLocalChain() async throws {
        let episodeID = EpisodeID()
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID)
        let server = InMemoryEpisodeSyncServer()
        let writerJournal = InMemoryEpisodeSyncJournal()
        let writer = EpisodeSyncCoordinator(
            key: key,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: writerJournal
        )
        let now = Date(timeIntervalSince1970: 10000)
        _ = try await writer.link(
            localContent: "B remote",
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        let remoteB = try #require(await server.currentHead(for: key))

        let appJournal = InMemoryEpisodeSyncJournal()
        let localA = try EpisodeRevision(
            key: key,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: "A local fork",
            clientCreatedAt: now.addingTimeInterval(1)
        )
        let originalConflict = EpisodeConflict(base: nil, local: localA, remote: remoteB)
        let localWorkingCopyID = LocalWorkingCopyID()
        try await appJournal.save(
            EpisodeSyncJournalRecord(
                key: key,
                localWorkingCopyID: localWorkingCopyID,
                branchID: localA.branchID,
                lastKnownRemoteHead: remoteB,
                localHead: localA,
                pendingRevisions: [localA],
                conflict: originalConflict,
                mode: .forcedFork
            )
        )

        let chapterID = ChapterID()
        let document = NovelDocument(
            title: "conflict",
            chapters: [
                Chapter(
                    id: chapterID,
                    title: "chapter",
                    episodes: [Episode(id: episodeID, content: "X package-only draft")]
                )
            ]
        )
        let url = packageURL("conflict-force-race")
        let repository = DeviceSyncAppRepository()
        await repository.seed(document, at: url)
        let resolution = try makeResolution(
            document: document,
            localWorkingCopyID: localWorkingCopyID,
            workID: key.workID,
            journal: appJournal
        )
        let mergeRecoveryStore = InMemoryDeviceSyncMergeRecoveryStore()
        let runtime = DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: server,
            binding: { _, _ in
                resolution
            },
            mergeRecoveryStore: mergeRecoveryStore,
            now: { now.addingTimeInterval(10) },
            leaseDuration: 600
        )
        let state = makeState(
            repository: repository,
            runtime: runtime,
            activeCommittedTextCapture: { .captured("X package-only draft") }
        )
        #expect(await state.openDocument(at: url))
        let lookup = try #require(state.currentDeviceSyncLookupIdentity)
        await state.prepareDeviceSync(for: lookup)
        let presentedConflict = try #require(state.deviceSyncConflict)
        // D-060ではpackageに先行していたXも失わず、元local Aの子revisionとして
        // journalへ昇格してから利用者へ提示する。
        #expect(presentedConflict.local.content == "X package-only draft")
        #expect(presentedConflict.local.parentRevisionIDs == [localA.revisionID])
        #expect(presentedConflict.remote == originalConflict.remote)
        #expect(state.document.episode(episodeID)?.episode.content == "X package-only draft")
        #expect(state.pendingDeviceSyncConflictResolution == nil)

        _ = try await writer.recordLocalContent("C raced remote", createdAt: now.addingTimeInterval(2))
        _ = try await writer.synchronize()
        let remoteC = try #require(await server.currentHead(for: key))
        #expect(remoteC.content == "C raced remote")

        await state.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: presentedConflict
        )

        var observedRemoteRace = false
        for _ in 0 ..< 2000 {
            if state.deviceSyncConflict?.remote.revisionID == remoteC.revisionID {
                observedRemoteRace = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(observedRemoteRace)
        let rebasedConflict = try #require(state.deviceSyncConflict)
        // 最初にmaterializeしたXのmerge revisionもremoteへ未送信のlocal chainであり、
        // Cとの再競合ではそのrevision自体を次のdirect parentとして保持する。
        #expect(rebasedConflict.local.content == presentedConflict.local.content)
        #expect(Set(rebasedConflict.local.parentRevisionIDs) == Set([
            presentedConflict.local.revisionID,
            remoteB.revisionID
        ]))
        #expect(rebasedConflict.remote.revisionID == remoteC.revisionID)
        #expect(state.pendingDeviceSyncConflictResolution?.content == presentedConflict.local.content)
        let loadedRebasedMarker = await mergeRecoveryStore.load(
            localWorkingCopyID: localWorkingCopyID,
            key: key
        )
        // tap直後の外部bridgeはdomain journalへchoiceをstageした時点で削除済み。
        #expect(loadedRebasedMarker == nil)
        await server.pauseNextPublish()
        await state.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: rebasedConflict
        )
        try #require(await waitUntilDeviceSyncPublishIsPaused(on: server))
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)

        // The external marker is only the tap-to-domain-stage bridge. Once the
        // staged choice is journal-durable it must already be gone, so remote
        // acknowledgement can finish after this editor surface departs.
        #expect(await state.selectProjectSectionAfterDeviceSyncDeparture(.settings))
        await server.resumePausedPublish()
        var didPublishFinalMerge = false
        for _ in 0 ..< 2000 {
            let remote = await server.currentHead(for: key)
            let record = await appJournal.storedRecord(for: key)
            if remote?.content == presentedConflict.local.content,
               remote?.revisionID == record?.localHead.revisionID,
               record?.pendingRevisions.isEmpty == true,
               record?.conflict == nil {
                didPublishFinalMerge = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(didPublishFinalMerge)

        let mergedHead = try #require(await server.currentHead(for: key))
        #expect(mergedHead.content == presentedConflict.local.content)
        #expect(Set(mergedHead.parentRevisionIDs) == Set([
            rebasedConflict.local.revisionID,
            remoteC.revisionID
        ]))
        #expect(!mergedHead.parentRevisionIDs.contains(remoteB.revisionID))
        #expect(state.document.episode(episodeID)?.episode.content == presentedConflict.local.content)
        #expect(state.deviceSyncConflict == nil)
        let storedRecord = try #require(await appJournal.storedRecord(for: key))
        #expect(storedRecord.conflict == nil)
        #expect(storedRecord.localHead.revisionID == mergedHead.revisionID)
        #expect(storedRecord.pendingRevisions.isEmpty)
        #expect(storedRecord.stagedConflictResolution == nil)
        #expect(storedRecord.conflictResolutionRecovery == nil)
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)

        // Relaunching after a relay/tail publish must never resurrect the old
        // accepted body as a future review draft.
        let relaunched = makeState(repository: repository, runtime: runtime)
        #expect(await relaunched.openDocument(at: url))
        try await relaunched.prepareDeviceSync(for: #require(relaunched.currentDeviceSyncLookupIdentity))
        #expect(await mergeRecoveryStore.load(localWorkingCopyID: localWorkingCopyID, key: key) == nil)
        #expect(relaunched.pendingDeviceSyncConflictResolution == nil)
        #expect(relaunched.deviceSyncConflict == nil)
    }

    private func makeState(
        repository: DeviceSyncAppRepository,
        runtime: DeviceSyncRuntime? = nil,
        activeCommittedTextCapture: (@MainActor () -> EditorCommittedTextCaptureResult)? = nil
    ) -> AppState {
        let suiteName = "FUMINIWA.DeviceSyncAppIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                activeCommittedTextCapture: activeCommittedTextCapture,
                deviceSyncRuntime: runtime
            ),
            initialStartupState: .ready
        )
    }

    private func waitUntilDeviceSyncClaimIsPaused(
        on server: InMemoryEpisodeSyncServer
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if await server.claimIsPaused() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncPublishIsPaused(
        on server: InMemoryEpisodeSyncServer
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if await server.publishIsPaused() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncSnapshotResponseIsPaused(
        on server: InMemoryEpisodeSyncServer
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if await server.snapshotResponseIsPaused() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncSettles(_ state: AppState) async -> Bool {
        for _ in 0 ..< 2000 {
            if state.deviceSyncState != .syncing, state.deviceSyncState != .forcing {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitUntilDeviceSyncCoordinatorStopsSynchronizing(
        _ coordinator: EpisodeSyncCoordinator
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if case .synchronizing = await coordinator.state {
                try? await Task.sleep(for: .milliseconds(1))
            } else {
                return true
            }
        }
        return false
    }

    private func makeFixture(content: String) -> (document: NovelDocument, url: URL) {
        let document = NovelDocument(
            title: "fixture",
            chapters: [Chapter(title: "chapter", episodes: [Episode(content: content)])]
        )
        return (document, packageURL("fixture-\(UUID().uuidString)"))
    }

    private func makeResolution(
        document: NovelDocument,
        localWorkingCopyID: LocalWorkingCopyID,
        workID: SyncWorkID,
        journal: any EpisodeSyncJournal
    ) throws -> DeviceSyncBindingResolution {
        try DeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: workID,
                sourceDocumentID: document.id,
                structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                title: document.title
            ),
            journal: journal,
            allowedEpisodeIDs: Set(document.chapters.flatMap(\.episodes).map(\.id))
        )
    }

    private func revision(
        key: EpisodeSyncKey,
        parents: [SyncRevisionID],
        content: String
    ) throws -> EpisodeRevision {
        try EpisodeRevision(
            key: key,
            parentRevisionIDs: parents,
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: content,
            clientCreatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func editIntentMarker(
        content: String,
        sequence: UInt64,
        documentID: UUID = UUID(),
        episodeID: EpisodeID = EpisodeID()
    ) -> DeviceSyncEditIntentMarker {
        DeviceSyncEditIntentMarker(
            protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: "test-working-copy",
            documentID: documentID,
            episodeID: episodeID,
            editorContentGeneration: sequence,
            mutationSequence: sequence,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: nil,
            workID: nil,
            baseContentDigest: nil,
            acceptedPriorPackageDigests: nil,
            content: content,
            contentDigest: SyncContentDigest(content: content)
        )
    }

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-DeviceSync-App-Tests", isDirectory: true)
            .appendingPathComponent("\(name).novelpkg", isDirectory: true)
    }
}

private actor DeviceSyncAppRepository: DocumentRepository {
    private var documents: [String: NovelDocument] = [:]
    private var saveObserver: (@Sendable (NovelDocument) async -> Void)?
    private var shouldPauseNextSave = false
    private var pausedSaveContinuation: CheckedContinuation<Void, Never>?

    func seed(_ document: NovelDocument, at url: URL) {
        documents[url.standardizedFileURL.path] = document
    }

    func load(from url: URL) async throws -> NovelDocument {
        guard let document = documents[url.standardizedFileURL.path] else {
            throw DeviceSyncAppRepositoryError.missingDocument
        }
        return document
    }

    func save(_ document: NovelDocument, to url: URL) async throws {
        documents[url.standardizedFileURL.path] = document
        if shouldPauseNextSave {
            shouldPauseNextSave = false
            await withCheckedContinuation { continuation in
                pausedSaveContinuation = continuation
            }
        }
        if let saveObserver {
            await saveObserver(document)
        }
    }

    func pauseNextSave() {
        shouldPauseNextSave = true
    }

    func waitUntilSaveIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if pausedSaveContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedSave() {
        pausedSaveContinuation?.resume()
        pausedSaveContinuation = nil
    }

    func setSaveObserver(_ observer: (@Sendable (NovelDocument) async -> Void)?) {
        saveObserver = observer
    }
}

private actor ConfirmFailureSaveObserver {
    private let episodeID: EpisodeID
    private let localContent: String
    private let remoteContent: String
    private let server: InMemoryEpisodeSyncServer
    private var observedLocalSave = false
    private var didTakeServerOffline = false

    init(
        episodeID: EpisodeID,
        localContent: String,
        remoteContent: String,
        server: InMemoryEpisodeSyncServer
    ) {
        self.episodeID = episodeID
        self.localContent = localContent
        self.remoteContent = remoteContent
        self.server = server
    }

    func observe(_ document: NovelDocument) async {
        guard let content = document.episode(episodeID)?.episode.content else { return }
        if content == localContent {
            observedLocalSave = true
        } else if observedLocalSave, content == remoteContent, !didTakeServerOffline {
            didTakeServerOffline = true
            await server.setOnline(false)
        }
    }

    func didTriggerFailure() -> Bool {
        didTakeServerOffline
    }
}

private actor DelayedDeviceSyncBindingResolver {
    private var lookupCount = 0
    private var firstContinuation: CheckedContinuation<DeviceSyncBindingResolution?, Never>?

    func resolve(_: DocumentSessionToken) async -> DeviceSyncBindingResolution? {
        lookupCount += 1
        guard lookupCount == 1 else { return nil }
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func waitUntilFirstLookupIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if firstContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumeFirstLookup(with resolution: DeviceSyncBindingResolution?) {
        firstContinuation?.resume(returning: resolution)
        firstContinuation = nil
    }

    func observedLookupCount() -> Int {
        lookupCount
    }
}

private actor PausableCountingDeviceSyncBindingResolver {
    private let resolution: DeviceSyncBindingResolution
    private var observedLookups = 0
    private var shouldPauseNextLookup = false
    private var pausedLookupContinuation: CheckedContinuation<Void, Never>?

    init(resolution: DeviceSyncBindingResolution) {
        self.resolution = resolution
    }

    func resolve() async -> DeviceSyncBindingResolution {
        observedLookups += 1
        if shouldPauseNextLookup {
            shouldPauseNextLookup = false
            await withCheckedContinuation { continuation in
                pausedLookupContinuation = continuation
            }
        }
        return resolution
    }

    func pauseNextLookup() {
        shouldPauseNextLookup = true
    }

    func waitUntilLookupIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if pausedLookupContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedLookup() {
        pausedLookupContinuation?.resume()
        pausedLookupContinuation = nil
    }

    func lookupCount() -> Int {
        observedLookups
    }
}

private actor LocalFirstBindingSequenceResolver {
    private let initial: DeviceSyncBindingResolution
    private let subsequent: DeviceSyncBindingResolution
    private var observedLookups = 0
    private var initialContinuation: CheckedContinuation<DeviceSyncBindingResolution, Never>?

    init(initial: DeviceSyncBindingResolution, subsequent: DeviceSyncBindingResolution) {
        self.initial = initial
        self.subsequent = subsequent
    }

    func resolve() async throws -> DeviceSyncBindingResolution {
        observedLookups += 1
        guard observedLookups == 1 else { return subsequent }
        return await withCheckedContinuation { continuation in
            initialContinuation = continuation
        }
    }

    func waitUntilInitialLookupIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if initialContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumeInitialLookup() {
        initialContinuation?.resume(returning: initial)
        initialContinuation = nil
    }

    func lookupCount() -> Int {
        observedLookups
    }
}

private actor FailingDeviceSyncEditIntentStore: DeviceSyncEditIntentStoring {
    private var stored: [DeviceSyncEditIntentMarker] = []
    private var remainingSaveFailures = 0
    private var alwaysFailsSave = false

    func seed(_ marker: DeviceSyncEditIntentMarker) {
        stored = [marker]
    }

    func failNextSaves(_ count: Int) {
        remainingSaveFailures = count
    }

    func failAllSaves() {
        alwaysFailsSave = true
    }

    func save(_ marker: DeviceSyncEditIntentMarker) async throws {
        if alwaysFailsSave || remainingSaveFailures > 0 {
            if remainingSaveFailures > 0 {
                remainingSaveFailures -= 1
            }
            throw DeviceSyncAppRepositoryError.injectedEditIntentFailure
        }
        stored.removeAll {
            $0.workingCopyIdentity == marker.workingCopyIdentity
                && $0.documentID == marker.documentID
                && $0.episodeID == marker.episodeID
        }
        stored.append(marker)
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [DeviceSyncEditIntentMarker] {
        stored.filter {
            $0.workingCopyIdentity == workingCopyIdentity
                && $0.documentID == documentID
                && $0.episodeID == episodeID
        }
    }

    func remove(_ marker: DeviceSyncEditIntentMarker) async throws {
        stored.removeAll { $0 == marker }
    }

    func markers() -> [DeviceSyncEditIntentMarker] {
        stored
    }
}

private actor PausablePreservedRemovalDeviceSyncEditIntentStore: DeviceSyncEditIntentStoring {
    private let storage = InMemoryDeviceSyncEditIntentStore()
    private var shouldPausePreservedRemoval = false
    private var preservedRemovalContinuation: CheckedContinuation<Void, Never>?
    private var shouldPausePreservation = false
    private var preservationContinuation: CheckedContinuation<Void, Never>?
    private var reconcileCounts: [EpisodeID: Int] = [:]
    private var pausedReconcileTarget: (episodeID: EpisodeID, invocation: Int)?
    private var reconcileContinuation: CheckedContinuation<Void, Never>?

    func pauseNextPreservedRemoval() {
        shouldPausePreservedRemoval = true
    }

    func waitUntilPreservedRemovalIsPaused() async -> Bool {
        for _ in 0 ..< 1000 {
            if preservedRemovalContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedPreservedRemoval() {
        preservedRemovalContinuation?.resume()
        preservedRemovalContinuation = nil
    }

    func pauseNextPreservation() {
        shouldPausePreservation = true
    }

    func waitUntilPreservationIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if preservationContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedPreservation() {
        preservationContinuation?.resume()
        preservationContinuation = nil
    }

    func pauseReconcilePreparedPackage(episodeID: EpisodeID, invocation: Int) {
        pausedReconcileTarget = (episodeID, invocation)
    }

    func waitUntilReconcileIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if reconcileContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedReconcile() {
        reconcileContinuation?.resume()
        reconcileContinuation = nil
    }

    func save(_ marker: DeviceSyncEditIntentMarker) async throws {
        try await storage.save(marker)
    }

    func save(
        _ marker: DeviceSyncEditIntentMarker,
        baselinePackageDigest: SyncContentDigest
    ) async throws -> DeviceSyncEditIntentMarker {
        try await storage.save(marker, baselinePackageDigest: baselinePackageDigest)
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [DeviceSyncEditIntentMarker] {
        try await storage.load(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func remove(_ marker: DeviceSyncEditIntentMarker) async throws {
        try await storage.remove(marker)
    }

    func preparePackageSave(_ checkpoint: DeviceSyncPackageCheckpoint) async throws {
        try await storage.preparePackageSave(checkpoint)
    }

    func commitPackageSave(_ checkpoint: DeviceSyncPackageCheckpoint) async throws {
        try await storage.commitPackageSave(checkpoint)
    }

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        try await storage.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func reconcilePreparedPackage(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        actualContentDigest: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        let snapshot = try await storage.reconcilePreparedPackage(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            actualContentDigest: actualContentDigest
        )
        let invocation = (reconcileCounts[episodeID] ?? 0) + 1
        reconcileCounts[episodeID] = invocation
        if let target = pausedReconcileTarget,
           target.episodeID == episodeID,
           target.invocation == invocation {
            pausedReconcileTarget = nil
            await withCheckedContinuation { continuation in
                reconcileContinuation = continuation
            }
        }
        return snapshot
    }

    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence: UInt64,
        contentDigest: SyncContentDigest
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        try await storage.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            throughSequence: throughSequence,
            contentDigest: contentDigest
        )
    }

    func preserveForReview(_ marker: DeviceSyncEditIntentMarker) async throws {
        try await storage.preserveForReview(marker)
        if shouldPausePreservation {
            shouldPausePreservation = false
            await withCheckedContinuation { continuation in
                preservationContinuation = continuation
            }
        }
    }

    func removePreservedForReview(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        expected: [DeviceSyncEditIntentMarker],
        expectedResolvingMarker: DeviceSyncEditIntentMarker
    ) async throws -> DeviceSyncLocalPersistenceSnapshot {
        if shouldPausePreservedRemoval {
            shouldPausePreservedRemoval = false
            await withCheckedContinuation { continuation in
                preservedRemovalContinuation = continuation
            }
        }
        return try await storage.removePreservedForReview(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            expected: expected,
            expectedResolvingMarker: expectedResolvingMarker
        )
    }
}

private enum DeviceSyncAppRepositoryError: Error {
    case injectedEditIntentFailure
    case missingDocument
    case rejectedPrivateCopy
}
