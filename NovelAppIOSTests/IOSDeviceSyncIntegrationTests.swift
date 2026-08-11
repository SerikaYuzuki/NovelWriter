import Foundation
import NovelCore
import NovelSync
import NovelSyncTesting
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS Device Sync integration", .serialized)
struct IOSDeviceSyncIntegrationTests {
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

        let draft = IOSDeviceSyncConflictDraft(
            conflict: EpisodeConflict(base: base, local: local, remote: remote)
        )

        #expect(draft.kind == .automaticIntegration)
        #expect(draft.content == "吾輩は黒猫である。名前はまだ無い。")
        #expect(draft.title == "自動統合の下書き")
    }

    @Test("iOS保存記号は端末保存・iCloud・オフライン・統合必要をVoiceOverで区別する")
    func editorStatusDistinguishesDurabilityAndPropagation() throws {
        let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
        let local = try revision(key: key, parents: [], content: "local")
        let remote = try revision(key: key, parents: [], content: "remote")
        let conflict = EpisodeConflict(base: nil, local: local, remote: remote)

        #expect(IOSDeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .unconfigured,
            transferState: .notApplicable,
            localDurability: .notApplicable
        ).accessibilityLabel == "この端末に保存済み")
        #expect(IOSDeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .writer,
            transferState: .upToDate,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、iCloudにも同期済み")
        #expect(IOSDeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .offlineLocal,
            transferState: .localPending,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、オフライン")
        #expect(IOSDeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .conflict(conflict),
            transferState: .localPending,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、統合が必要")
        #expect(IOSDeviceSyncEditorStatusKind.resolve(
            saveState: .saved,
            syncState: .blocked,
            transferState: .notApplicable,
            localDurability: .saved
        ).accessibilityLabel == "この端末に保存済み、同期設定を確認")

        let pendingReview = IOSDeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .pending,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: true,
            reviewChanges: {}
        )
        #expect(pendingReview.resolvedStatus == .savingLocally)
        let failedReview = IOSDeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .failed,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: false,
            reviewChanges: {}
        )
        #expect(failedReview.resolvedStatus == .localSaveError)
        let durableReview = IOSDeviceSyncStatusControl(
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

    @Test("iOS本文WALは最新一件だけを保持しsequence resetとJSON escape境界を安全に読む")
    func productionEditIntentStoreKeepsOnlyLatestBody() async throws {
        let fileManager = FileManager.default
        let trusted = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-WAL-Latest-\(UUID().uuidString)", isDirectory: true)
        let root = trusted
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("DeviceSync-v1", isDirectory: true)
        try fileManager.createDirectory(at: trusted, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: trusted) }
        let store = try IOSFileDeviceSyncEditIntentStore(rootURL: root, trustedAncestorURL: trusted)
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
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            try await store.save(oversized)
        }
    }

    @Test("iOS本文WALは中間symlink・root差し替え・最終symlinkを拒否する")
    func productionEditIntentStorePinsTrustedRoot() async throws {
        let fileManager = FileManager.default
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-WAL-Root-\(UUID().uuidString)", isDirectory: true)
        let trusted = base.appendingPathComponent("trusted", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: trusted, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let linkedParent = trusted.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            _ = try IOSFileDeviceSyncEditIntentStore(
                rootURL: linkedParent.appendingPathComponent("DeviceSync-v1", isDirectory: true),
                trustedAncestorURL: trusted
            )
        }

        let root = trusted.appendingPathComponent("pinned", isDirectory: true)
        let store = try IOSFileDeviceSyncEditIntentStore(rootURL: root, trustedAncestorURL: trusted)
        let marker = editIntentMarker(content: "safe", sequence: 1)
        let moved = trusted.appendingPathComponent("moved", isDirectory: true)
        try fileManager.moveItem(at: root, to: moved)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            try await store.save(marker)
        }

        let finalRoot = trusted.appendingPathComponent("final", isDirectory: true)
        let finalStore = try IOSFileDeviceSyncEditIntentStore(rootURL: finalRoot, trustedAncestorURL: trusted)
        try await finalStore.save(marker)
        let recordURL = try #require(
            fileManager.contentsOfDirectory(at: finalRoot, includingPropertiesForKeys: nil).first
        )
        try fileManager.removeItem(at: recordURL)
        let forged = outside.appendingPathComponent("forged.json")
        try Data("forged".utf8).write(to: forged)
        try fileManager.createSymbolicLink(at: recordURL, withDestinationURL: forged)
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            _ = try await finalStore.load(
                workingCopyIdentity: marker.workingCopyIdentity,
                documentID: marker.documentID,
                episodeID: marker.episodeID
            )
        }
    }

    @Test("iOS同一sequenceの異なる本文または復旧参照でWALを上書きしない")
    func editIntentStoreRejectsDifferentPayloadAtSameSequence() async throws {
        let store = IOSInMemoryDeviceSyncEditIntentStore()
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
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            _ = try await store.save(
                differentContent,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
        }
        var differentResolution = first
        differentResolution.resolvesPreservedSequences = [1]
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            _ = try await store.save(
                differentResolution,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
        }
    }

    @Test("初回本文WALだけが残った再起動はbase一致時だけ最新本文を復元する")
    func firstBoundIntentRecoversBeforeAnyJournalBaseline() async throws {
        let fixture = try makeFixture(content: "P0 package")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let resolver = IOSDelayedDeviceSyncBindingResolver()
        let resolution = IOSDeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: fixture.key.workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: fixture.key.workID,
                sourceDocumentID: fixture.document.id,
                structureDigest: fixture.structureDigest,
                title: fixture.document.title
            ),
            journal: journal,
            allowedEpisodeIDs: [fixture.episodeID]
        )
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: replicaID,
            packageName: "first-intent-recovery.novelpkg",
            localWorkingCopyID: localWorkingCopyID,
            editIntentStore: editIntents,
            binding: { _, _, _ in await resolver.resolve() }
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let marker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
            mutationSequence: 2,
            createdAt: Date(timeIntervalSince1970: 2),
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            workID: fixture.key.workID,
            baseContentDigest: SyncContentDigest(content: "P0 package"),
            acceptedPriorPackageDigests: [SyncContentDigest(content: "P0 package")],
            content: "P2 WAL latest",
            contentDigest: SyncContentDigest(content: "P2 WAL latest")
        )
        try await editIntents.save(marker)
        await app.repository.pauseNextSave()

        let originalLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let firstPreparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: originalLookup)
        }
        #expect(await app.repository.waitUntilSaveIsPaused())
        let recoveredLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        #expect(recoveredLookup != originalLookup)
        let duplicatePreparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: recoveredLookup)
        }
        await Task.yield()
        #expect(await resolver.observedLookupCount() == 0)
        await app.repository.resumePausedSave()
        await resolver.waitUntilLookupIsPaused()
        #expect(await resolver.observedLookupCount() == 1)
        await resolver.resume(with: resolution)
        await firstPreparation.value
        await duplicatePreparation.value

        let package = try await app.repository.load(from: app.store.documentURL)
        let record = try #require(await journal.storedRecord(for: fixture.key))
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "P2 WAL latest")
        #expect(package.episode(fixture.episodeID)?.episode.content == "P2 WAL latest")
        #expect(record.localHead.content == "P2 WAL latest")
        #expect(await server.currentHead(for: fixture.key)?.content == "P2 WAL latest")
        #expect(await resolver.observedLookupCount() == 1)
        #expect(try await editIntents.load(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        ).isEmpty)
    }

    @Test("本文WAL失敗後のpackage checkpointだけでも再起動時に明示編集を復元する")
    func packageCheckpointRecoversEditWhenIntentMarkerWasNotSaved() async throws {
        let fixture = try makeFixture(content: "package survived")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: replicaID,
            packageName: "checkpoint-intent-recovery.novelpkg",
            editIntentStore: editIntents
        )
        let session = try #require(app.store.currentDocumentSessionToken)
        let checkpoint = IOSDeviceSyncPackageCheckpoint(
            protocolVersion: IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(for: session.workingCopyID),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            sequence: 1,
            contentDigest: SyncContentDigest(content: "package survived"),
            containsLocalEditIntent: true
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)

        await prepareSelectedEpisode(in: app.store)

        #expect(await server.currentHead(for: fixture.key)?.content == "package survived")
        let persisted = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: checkpoint.workingCopyIdentity,
            documentID: checkpoint.documentID,
            episodeID: checkpoint.episodeID
        )
        #expect(persisted.committedPackage?.containsLocalEditIntent == false)
    }

    @Test("iOS隔離本文は未設定作品で編集を続けても削除・remote送信しない")
    func preservedRecoveryRemainsUntilRemoteAcknowledgement() async throws {
        let fixture = try makeFixture(content: "current package")
        let server = InMemoryEpisodeSyncServer()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "preserved-unconfigured.novelpkg",
            editIntentStore: editIntents,
            binding: { _, _, _ in nil }
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let marker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
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

        await prepareSelectedEpisode(in: app.store)
        let review = try #require(app.store.deviceSyncLocalRecoveryReview)
        #expect(app.store.deviceSyncState == .needsReview)
        #expect(app.store.deviceSyncAllowsEditing(for: lookup))
        await app.store.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)

        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(snapshot.preservedMarkers == [marker])
        #expect(app.store.deviceSyncLocalRecoveryReview != nil)
        #expect(await server.currentHead(for: fixture.key) == nil)
    }

    @Test("iOS隔離上限では4本文を保持して選択・remote送信を拒否する")
    func preservedRecoveryCapacityFailsClosedWithoutOverwritingActiveEvidence() async throws {
        let fixture = try makeFixture(content: "package body")
        let server = InMemoryEpisodeSyncServer()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "preserved-capacity.novelpkg",
            editIntentStore: editIntents,
            binding: { _, _, _ in nil }
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let workingCopyIdentity = app.store.deviceSyncWorkingCopyIdentity(
            for: lookup.editingToken.documentSession.workingCopyID
        )
        let marker: (UInt64) -> IOSDeviceSyncEditIntentMarker = { sequence in
            let content = "recovery body \(sequence)"
            return IOSDeviceSyncEditIntentMarker(
                protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
                workingCopyIdentity: workingCopyIdentity,
                documentID: fixture.document.id,
                episodeID: fixture.episodeID,
                editorContentGeneration: lookup.editingToken.editorContentGeneration,
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

        await prepareSelectedEpisode(in: app.store)
        let review = try #require(app.store.deviceSyncLocalRecoveryReview)
        #expect(review.preservedMarkers.count == 4)
        #expect(app.store.deviceSyncLocalRecoveryPending)
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)
        await app.store.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)

        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: workingCopyIdentity,
            documentID: fixture.document.id,
            episodeID: fixture.episodeID
        )
        #expect(snapshot.preservedMarkers.count == 3)
        #expect(snapshot.marker == active)
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "package body")
        #expect(app.store.activeDeviceSyncIdentity == nil)
        #expect(await server.currentHead(for: fixture.key) == nil)
    }

    @Test("iOS隔離本文はpackage・journal・remote確認後だけまとめて削除する")
    func preservedRecoveryClearsAfterRemoteAcknowledgement() async throws {
        let fixture = try makeFixture(content: "accepted body")
        let server = InMemoryEpisodeSyncServer()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "preserved-online.novelpkg",
            editIntentStore: editIntents
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let marker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
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
        await prepareSelectedEpisode(in: app.store)
        let review = try #require(app.store.deviceSyncLocalRecoveryReview)

        await app.store.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        for _ in 0 ..< 100 where app.store.deviceSyncLocalRecoveryReview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await server.currentHead(for: fixture.key)?.content == "accepted body")
        #expect(app.store.deviceSyncLocalRecoveryReview == nil)
        let snapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(snapshot.preservedMarkers.isEmpty)
    }

    @Test("iOS同一本文の古い復旧証拠を選んでも新しいsequenceでremote確認まで完了する")
    func sameBodyRecoveryChoiceAdvancesSequenceBeforeAcknowledgement() async throws {
        let fixture = try makeFixture(content: "accepted body")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = IOSPausablePreservedRemovalDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "preserved-same-sequence.novelpkg",
            editIntentStore: editIntents
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let marker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
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
        let checkpoint = IOSDeviceSyncPackageCheckpoint(
            protocolVersion: IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID,
            sequence: 1,
            contentDigest: marker.contentDigest,
            containsLocalEditIntent: false
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)

        await prepareSelectedEpisode(in: app.store)
        let review = try #require(app.store.deviceSyncLocalRecoveryReview)
        await editIntents.pauseNextPreservedRemoval()
        await app.store.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        #expect(await editIntents.waitUntilPreservedRemovalIsPaused())

        let staged = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(staged.marker?.mutationSequence == 2)
        #expect(staged.marker?.resolvesPreservedSequences == [1])

        await editIntents.resumePausedPreservedRemoval()
        for _ in 0 ..< 100 where app.store.deviceSyncLocalRecoveryReview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.currentHead(for: fixture.key)?.content == "accepted body")
        let completed = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(completed.marker == nil)
        #expect(completed.preservedMarkers.isEmpty)
    }

    @Test("iOS新しいpackage checkpointは古いWALを次sequenceへ置換して再起動復旧する")
    func newerPackageCheckpointSupersedesStaleMarkerWithNewSequence() async throws {
        let fixture = try makeFixture(content: "accepted body")
        let server = InMemoryEpisodeSyncServer()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let replicaID = SyncReplicaID()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: replicaID,
            packageName: "checkpoint-supersedes-wal.novelpkg",
            editIntentStore: editIntents
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let stale = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
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
        let checkpoint = IOSDeviceSyncPackageCheckpoint(
            protocolVersion: IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID,
            sequence: 2,
            contentDigest: SyncContentDigest(content: "accepted body"),
            containsLocalEditIntent: true
        )
        try await editIntents.preparePackageSave(checkpoint)
        try await editIntents.commitPackageSave(checkpoint)

        await prepareSelectedEpisode(in: app.store)
        for _ in 0 ..< 100 {
            if await server.currentHead(for: fixture.key) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "accepted body")
        #expect(app.store.deviceSyncAllowsEditing(for: lookup))
        #expect(await server.currentHead(for: fixture.key)?.content == "accepted body")
        let completed = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: stale.workingCopyIdentity,
            documentID: stale.documentID,
            episodeID: stale.episodeID
        )
        #expect(completed.marker == nil)
        #expect(completed.committedPackage?.containsLocalEditIntent == false)
    }

    @Test("iOS古いremote確認は同本文へ戻った新しいWALを削除しない")
    func staleRecoveryCompletionCannotDeleteNetZeroTailMarker() async throws {
        let fixture = try makeFixture(content: "accepted body")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = IOSPausablePreservedRemovalDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "preserved-tail-cas.novelpkg",
            editIntentStore: editIntents
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let evidence = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
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
        await prepareSelectedEpisode(in: app.store)
        let review = try #require(app.store.deviceSyncLocalRecoveryReview)

        await editIntents.pauseNextPreservedRemoval()
        await app.store.resolveDeviceSyncLocalRecovery(using: .current, expectedReview: review)
        #expect(await editIntents.waitUntilPreservedRemovalIsPaused())

        let runtime = try #require(app.store.deviceSyncRuntime)
        let editingToken = try #require(app.store.currentEpisodeEditingToken)
        for content in ["temporary tail", "accepted body"] {
            app.store.updateEpisodeContent(
                content,
                chapterID: fixture.chapterID,
                episodeID: fixture.episodeID,
                expectedEditingToken: editingToken
            )
        }
        app.store.deviceSyncDraftTask?.cancel()
        app.store.deviceSyncDraftTask = nil
        #expect(await app.store.flushPendingDeviceSyncEditIntents())
        app.store.saveCoordinator.markDirty()
        #expect(await app.store.saveCoordinator.saveNow())
        let identity = try #require(app.store.activeDeviceSyncIdentity)
        let client = try #require(app.store.deviceSyncClient(for: identity))
        let tailSnapshot = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        let tailMarker = try #require(tailSnapshot.marker)
        let receipt = try await client.coordinator.recordLocalEdit(
            "accepted body",
            createdAt: runtime.now()
        )
        await app.store.markDeviceSyncLocalEditSavedIfCurrent(
            receipt,
            content: "accepted body",
            expectedIdentity: identity,
            acknowledgedMutationSequence: tailMarker.mutationSequence
        )
        app.store.applyDeviceSyncState(receipt.state, client: client, expectedIdentity: identity)

        await editIntents.resumePausedPreservedRemoval()
        await Task.yield()
        var retained = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: evidence.workingCopyIdentity,
            documentID: evidence.documentID,
            episodeID: evidence.episodeID
        )
        #expect(retained.preservedMarkers == [evidence])
        #expect(retained.marker == tailMarker)

        let synchronized = try await client.coordinator.synchronizeLocalFirst(
            expiresAt: runtime.leaseExpiration(),
            createdAt: runtime.now()
        )
        #expect(await app.store.completeDeviceSyncLocalRecoveryReviewIfConfirmed(
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

    @Test("同じ話の同期準備は一つのbinding lookupへ合流する")
    func duplicatePreparationJoinsSingleBindingLookup() async throws {
        let fixture = try makeFixture(content: "single flight")
        let resolver = IOSDelayedDeviceSyncBindingResolver()
        let app = try makeStore(
            fixture: fixture,
            server: InMemoryEpisodeSyncServer(),
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "single-flight.novelpkg",
            binding: { _, _, _ in
                await resolver.resolve()
            }
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)

        let first = Task { @MainActor in
            await app.store.prepareDeviceSync(for: lookup)
        }
        await resolver.waitUntilLookupIsPaused()
        let second = Task { @MainActor in
            await app.store.prepareDeviceSync(for: lookup)
        }
        await Task.yield()

        #expect(await resolver.observedLookupCount() == 1)
        await resolver.resume(with: nil)
        await first.value
        await second.value

        #expect(await resolver.observedLookupCount() == 1)
        #expect(app.store.deviceSyncState == .unconfigured)
        #expect(app.store.resolvedDeviceSyncLookupIdentity == lookup)
    }

    @Test("遅い旧binding lookupは新しい話の同期状態を上書きしない")
    func staleBindingLookupCannotOverwriteNewSelection() async throws {
        let fixture = try makeTwoChapterFixture(
            title: "lookup race",
            firstContent: "first",
            secondContent: "second"
        )
        let resolver = IOSStaleDeviceSyncBindingResolver()
        let journal = InMemoryEpisodeSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let resolution = IOSDeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: fixture.key.workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: fixture.key.workID,
                sourceDocumentID: fixture.document.id,
                structureDigest: fixture.structureDigest,
                title: fixture.document.title
            ),
            journal: journal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id))
        )
        let app = try makeStore(
            fixture: fixture,
            server: InMemoryEpisodeSyncServer(),
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "lookup-race.novelpkg",
            localWorkingCopyID: localWorkingCopyID,
            binding: { _, _, _ in await resolver.resolve() }
        )
        let staleLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let stalePreparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: staleLookup)
        }
        #expect(await resolver.waitUntilFirstLookupIsPaused())

        let secondChapter = fixture.document.chapters[1]
        app.store.selectChapter(secondChapter.id)
        let currentLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let currentPreparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: currentLookup)
        }
        for _ in 0 ..< 100 {
            if app.store.deviceSyncAllowsEditing(for: currentLookup) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(app.store.deviceSyncAllowsEditing(for: currentLookup))
        #expect(await resolver.observedLookupCount() == 2)

        await resolver.resumeFirstLookup(with: resolution)
        await stalePreparation.value
        await currentPreparation.value

        #expect(app.store.currentDeviceSyncLookupIdentity == currentLookup)
        #expect(app.store.resolvedDeviceSyncLookupIdentity == currentLookup)
        #expect(app.store.activeDeviceSyncIdentity == nil)
        #expect(app.store.deviceSyncState == .unconfigured)
    }

    @Test("旧話のWAL隔離完了は新しい話の本文と復旧状態を上書きしない")
    func stalePreservedMarkerCompletionCannotOverwriteNewSelection() async throws {
        let fixture = try makeTwoChapterFixture(
            title: "stale local recovery",
            firstContent: "old package",
            secondContent: "new package"
        )
        let store = IOSPausablePreservedRemovalDeviceSyncEditIntentStore()
        let server = InMemoryEpisodeSyncServer()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "stale-local-recovery.novelpkg",
            editIntentStore: store,
            binding: { _, _, _ in nil }
        )
        let staleLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let firstEpisode = fixture.document.chapters[0].episodes[0]
        let secondEpisode = fixture.document.chapters[1].episodes[0]
        let marker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: staleLookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: firstEpisode.id,
            editorContentGeneration: staleLookup.editingToken.editorContentGeneration,
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
            await app.store.prepareDeviceSync(for: staleLookup)
        }
        #expect(await store.waitUntilPreservationIsPaused())

        let secondChapter = fixture.document.chapters[1]
        app.store.selectChapter(secondChapter.id)
        let currentLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        await app.store.prepareDeviceSync(for: currentLookup)
        #expect(app.store.deviceSyncAllowsEditing(for: currentLookup))
        let currentToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "new edited body",
            chapterID: secondChapter.id,
            episodeID: secondEpisode.id,
            expectedEditingToken: currentToken
        )
        #expect(await app.store.saveNow())

        await store.resumePausedPreservation()
        await stalePreparation.value

        let oldSnapshot = try await store.loadPersistenceSnapshot(
            workingCopyIdentity: marker.workingCopyIdentity,
            documentID: marker.documentID,
            episodeID: marker.episodeID
        )
        #expect(oldSnapshot.marker == nil)
        #expect(oldSnapshot.preservedMarkers == [marker])
        #expect(app.store.document.episode(secondEpisode.id)?.episode.content == "new edited body")
        #expect(app.store.currentDeviceSyncLookupIdentity?.editingToken.episodeID == secondEpisode.id)
        #expect(app.store.deviceSyncLocalRecoveryReview == nil)
        #expect(app.store.deviceSyncState == .unconfigured)
        #expect(await server.snapshotFetchInvocationCount() == 0)
    }

    @Test("旧話のpackage-only完了は新しい話の保存状態を上書きしない")
    func stalePackageOnlyCompletionCannotOverwriteNewSelection() async throws {
        let fixture = try makeTwoChapterFixture(
            title: "stale package only",
            firstContent: "old local",
            secondContent: "new local"
        )
        let store = IOSPausablePreservedRemovalDeviceSyncEditIntentStore()
        let server = InMemoryEpisodeSyncServer()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "stale-package-only.novelpkg",
            editIntentStore: store,
            binding: { _, _, _ in nil }
        )
        let staleLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let firstEpisode = fixture.document.chapters[0].episodes[0]
        let secondChapter = fixture.document.chapters[1]
        let secondEpisode = secondChapter.episodes[0]
        await store.pauseReconcilePreparedPackage(episodeID: firstEpisode.id, invocation: 2)
        let stalePreparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: staleLookup)
        }
        #expect(await store.waitUntilReconcileIsPaused())

        app.store.selectChapter(secondChapter.id)
        let currentLookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        await app.store.prepareDeviceSync(for: currentLookup)
        #expect(app.store.deviceSyncAllowsEditing(for: currentLookup))
        let currentToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "new package-only edit",
            chapterID: secondChapter.id,
            episodeID: secondEpisode.id,
            expectedEditingToken: currentToken
        )
        #expect(await app.store.saveNow())
        let stateBeforeResume = app.store.deviceSyncState
        let durabilityBeforeResume = app.store.deviceSyncLocalDurabilityState

        await store.resumePausedReconcile()
        await stalePreparation.value

        #expect(app.store.document.episode(secondEpisode.id)?.episode.content == "new package-only edit")
        #expect(app.store.currentDeviceSyncLookupIdentity?.editingToken.episodeID == secondEpisode.id)
        #expect(app.store.deviceSyncLocalRecoveryReview == nil)
        #expect(app.store.deviceSyncState == stateBeforeResume)
        #expect(app.store.deviceSyncLocalDurabilityState == durabilityBeforeResume)
        #expect(await server.snapshotFetchInvocationCount() == 0)
    }

    @Test("local-only準備中のready通知は同じEditorを再解決して保留本文を送る")
    func readySignalDuringLocalOnlyPreparationIsRevalidated() async throws {
        let fixture = try makeFixture(content: "local base")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: localWorkingCopyID,
            workID: fixture.key.workID
        )
        let localOnly = IOSDeviceSyncBindingResolution(
            binding: binding,
            descriptor: nil,
            journal: journal,
            allowedEpisodeIDs: [fixture.episodeID]
        )
        let remoteReady = IOSDeviceSyncBindingResolution(
            binding: binding,
            descriptor: SyncWorkDescriptor(
                workID: fixture.key.workID,
                sourceDocumentID: fixture.document.id,
                structureDigest: fixture.structureDigest,
                title: fixture.document.title
            ),
            journal: journal,
            allowedEpisodeIDs: [fixture.episodeID]
        )
        let resolver = IOSLocalFirstBindingSequenceResolver(
            initial: localOnly,
            subsequent: remoteReady
        )
        let signal = AsyncStream<Void>.makeStream()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "local-only-ready-signal.novelpkg",
            localWorkingCopyID: localWorkingCopyID,
            remoteChangeSignals: signal.stream,
            binding: { _, _, _ in try await resolver.resolve() }
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let preparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: lookup)
        }
        await resolver.waitUntilInitialLookupIsPaused()

        let editingToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "pending while local only",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: editingToken
        )
        signal.continuation.yield(())
        await resolver.resumeInitialLookup()
        await preparation.value

        for _ in 0 ..< 100 {
            if await server.currentHead(for: fixture.key)?.content == "pending while local only" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        signal.continuation.finish()

        #expect(await resolver.lookupCount() >= 2)
        #expect(await server.currentHead(for: fixture.key)?.content == "pending while local only")
        #expect(app.store.selectedEpisodeID == fixture.episodeID)
        #expect(app.store.deviceSyncTransferState == .upToDate)
    }

    @Test("prepare中のIME確定は古いWALを入れずpackageとjournalへ保存する")
    func markedTextCommittedDuringPreparationBeatsStoredIntent() async throws {
        let fixture = try makeFixture(content: "本文")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let baseline = EpisodeSyncCoordinator(
            key: fixture.key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: journal
        )
        _ = try await baseline.observeLocalBase(
            localContent: fixture.content,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let editIntents = IOSPausableDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: replicaID,
            packageName: "prepare-ime-recovery.novelpkg",
            localWorkingCopyID: localWorkingCopyID,
            editIntentStore: editIntents
        )
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let staleMarker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
            mutationSequence: 1,
            createdAt: Date(timeIntervalSince1970: 2),
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            workID: fixture.key.workID,
            baseContentDigest: SyncContentDigest(content: fixture.content),
            acceptedPriorPackageDigests: [SyncContentDigest(content: fixture.content)],
            content: "古いWAL",
            contentDigest: SyncContentDigest(content: "古いWAL")
        )
        try await editIntents.seed(staleMarker)
        await editIntents.pauseNextLoad()
        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }

        let preparation = Task { @MainActor in
            await app.store.prepareDeviceSync(for: lookup)
        }
        #expect(await editIntents.waitUntilLoadIsPaused())
        beginMarkedText("変換確定", in: harness.textView)
        #expect(harness.textView.markedTextRange != nil)
        await editIntents.resumePausedLoad()
        await preparation.value
        await advanceMainRunLoop(iterations: 4)

        let expected = "本文変換確定"
        let package = try await app.repository.load(from: app.store.documentURL)
        let record = try #require(await journal.storedRecord(for: fixture.key))
        #expect(harness.textView.text == expected)
        #expect(harness.textView.markedTextRange == nil)
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == expected)
        #expect(package.episode(fixture.episodeID)?.episode.content == expected)
        #expect(record.localHead.content == expected)
        #expect(await editIntents.markers().isEmpty)
    }

    @Test("新WAL失敗後もpackage本文を保存し古いWALでは巻き戻さない")
    func failedLatestIntentCannotRollBackSavedPackage() async throws {
        let fixture = try makeFixture(content: "初期本文")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let replicaID = SyncReplicaID()
        let editIntents = IOSFailingDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: replicaID,
            packageName: "wal-failure-package.novelpkg",
            localWorkingCopyID: localWorkingCopyID,
            editIntentStore: editIntents
        )
        await prepareSelectedEpisode(in: app.store)
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let staleMarker = IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID,
            editorContentGeneration: lookup.editingToken.editorContentGeneration,
            mutationSequence: 10,
            createdAt: Date(timeIntervalSince1970: 10),
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            workID: fixture.key.workID,
            baseContentDigest: SyncContentDigest(content: fixture.content),
            acceptedPriorPackageDigests: [SyncContentDigest(content: fixture.content)],
            content: "古い復旧証拠",
            contentDigest: SyncContentDigest(content: "古い復旧証拠")
        )
        await editIntents.seed(staleMarker)
        await editIntents.failAllSaves()
        let token = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "packageが保持する新本文",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: token
        )
        #expect(await app.store.flushDeviceSyncForBackground())
        let saved = try await app.repository.load(from: app.store.documentURL)
        #expect(saved.episode(fixture.episodeID)?.episode.content == "packageが保持する新本文")
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)

        let relaunchedFixture = IOSDeviceSyncFixture(
            document: saved,
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            key: fixture.key,
            structureDigest: fixture.structureDigest,
            content: "packageが保持する新本文"
        )
        let relaunched = try makeStore(
            fixture: relaunchedFixture,
            server: server,
            journal: journal,
            replicaID: replicaID,
            packageName: "wal-failure-package.novelpkg",
            localWorkingCopyID: localWorkingCopyID,
            editIntentStore: editIntents
        )
        await prepareSelectedEpisode(in: relaunched.store)

        #expect(relaunched.store.document.episode(fixture.episodeID)?.episode.content == "packageが保持する新本文")
        #expect(relaunched.store.deviceSyncLocalDurabilityState == .failed)
        #expect(await editIntents.markers() == [staleMarker])
    }

    @Test("iOS入力時に永続化済みのWALをpublishが再利用してjournalとremoteまで確定する")
    func publishReusesPersistedInputIntent() async throws {
        let fixture = try makeFixture(content: "initial")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = IOSInMemoryDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "persisted-input-intent.novelpkg",
            editIntentStore: editIntents
        )
        await prepareSelectedEpisode(in: app.store)
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        let token = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "latest input",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: token
        )
        #expect(await app.store.flushPendingDeviceSyncEditIntents())
        let persisted = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: app.store.deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            ),
            documentID: fixture.document.id,
            episodeID: fixture.episodeID
        )
        let persistedMarker = try #require(persisted.marker)
        #expect(persistedMarker.content == "latest input")

        app.store.deviceSyncDraftTask?.cancel()
        app.store.deviceSyncDraftTask = nil
        await app.store.publishDeviceSyncDraft(
            content: "latest input",
            expectedEditingToken: token
        )

        let package = try await app.repository.load(from: app.store.documentURL)
        let record = try #require(await journal.storedRecord(for: fixture.key))
        let settled = try await editIntents.loadPersistenceSnapshot(
            workingCopyIdentity: persistedMarker.workingCopyIdentity,
            documentID: persistedMarker.documentID,
            episodeID: persistedMarker.episodeID
        )
        #expect(package.episode(fixture.episodeID)?.episode.content == "latest input")
        #expect(record.localHead.content == "latest input")
        #expect(await server.currentHead(for: fixture.key)?.content == "latest input")
        #expect(settled.marker == nil)
        #expect(app.store.deviceSyncLocalDurabilityState == .saved)
    }

    @Test("WAL一時失敗は追加入力なしの次回保存でjournalまで再試行する")
    func transientIntentFailureRetriesLatestBodyOnNextSave() async throws {
        let fixture = try makeFixture(content: "初期本文")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let editIntents = IOSFailingDeviceSyncEditIntentStore()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "wal-transient-retry.novelpkg",
            editIntentStore: editIntents
        )
        await prepareSelectedEpisode(in: app.store)
        await editIntents.failNextSaves(2)
        let token = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "一度失敗した最新本文",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: token
        )
        await app.store.deviceSyncDraftTask?.value
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)

        #expect(await app.store.flushDeviceSyncForBackground())

        let package = try await app.repository.load(from: app.store.documentURL)
        let record = try #require(await journal.storedRecord(for: fixture.key))
        #expect(package.episode(fixture.episodeID)?.episode.content == "一度失敗した最新本文")
        #expect(record.localHead.content == "一度失敗した最新本文")
        #expect(await editIntents.markers().isEmpty)
        #expect(app.store.deviceSyncLocalDurabilityState == .saved)
    }

    @Test("同じ話の重複refreshは一つのremote検査へ合流する")
    func duplicateRefreshJoinsSingleRemoteInspection() async throws {
        let fixture = try makeFixture(content: "R0")
        let server = InMemoryEpisodeSyncServer()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "duplicate-refresh.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        let editingToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "R1",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: editingToken
        )
        app.store.deviceSyncDraftTask?.cancel()
        app.store.deviceSyncDraftTask = nil
        await app.store.publishDeviceSyncDraft(content: "R1", expectedEditingToken: editingToken)
        #expect(app.store.deviceSyncState == .writer)

        let initialFetchCount = await server.snapshotFetchInvocationCount()
        await server.pauseNextSnapshotResponseAfterCapture()
        let first = Task { @MainActor in
            await app.store.refreshSelectedEpisodeDeviceSync()
        }
        var reachedSnapshotPause = false
        for _ in 0 ..< 2000 {
            if await server.snapshotResponseIsPaused() {
                reachedSnapshotPause = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(reachedSnapshotPause)
        let second = Task { @MainActor in
            await app.store.refreshSelectedEpisodeDeviceSync()
        }
        await Task.yield()

        #expect(await server.snapshotFetchInvocationCount() == initialFetchCount + 1)
        await server.resumePausedSnapshotResponse()
        await first.value
        await second.value

        #expect(await server.snapshotFetchInvocationCount() == initialFetchCount + 1)
        #expect(app.store.deviceSyncState == .writer)
    }

    @Test("旧claim応答は離脱後に再取得したauthorityを解放しない")
    func staleClaimCannotReleaseAuthorityAfterReselection() async throws {
        let fixture = try makeFixture(content: "shared")
        let server = InMemoryEpisodeSyncServer()
        let first = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "claim-race-first.novelpkg"
        )
        let secondReplicaID = SyncReplicaID()
        let second = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: secondReplicaID,
            packageName: "claim-race-second.novelpkg"
        )
        await prepareSelectedEpisode(in: first.store)
        let firstToken = try #require(first.store.currentEpisodeEditingToken)
        for content in ["temporary first edit", "shared"] {
            first.store.updateEpisodeContent(
                content,
                chapterID: fixture.chapterID,
                episodeID: fixture.episodeID,
                expectedEditingToken: firstToken
            )
        }
        first.store.deviceSyncDraftTask?.cancel()
        first.store.deviceSyncDraftTask = nil
        await first.store.publishDeviceSyncDraft(content: "shared", expectedEditingToken: firstToken)
        await prepareSelectedEpisode(in: second.store)
        #expect(first.store.deviceSyncState == .writer)
        #expect(second.store.deviceSyncState == .readOnly)

        let firstIdentity = try #require(first.store.activeDeviceSyncIdentity)
        let firstClient = try #require(first.store.deviceSyncClient(for: firstIdentity))
        _ = try await firstClient.coordinator.releaseEditingAuthority()

        await server.pauseNextClaim()
        let secondToken = try #require(second.store.currentEpisodeEditingToken)
        second.store.updateEpisodeContent(
            "second local edit",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: secondToken
        )
        second.store.deviceSyncDraftTask?.cancel()
        second.store.deviceSyncDraftTask = nil
        let stalePublish = Task { @MainActor in
            await second.store.publishDeviceSyncDraft(
                content: "second local edit",
                expectedEditingToken: secondToken
            )
        }
        var reachedClaim = false
        for _ in 0 ..< 2000 {
            if await server.claimIsPaused() {
                reachedClaim = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(reachedClaim)

        #expect(await second.store.prepareForEditorSurfaceDeparture())
        let reselectionLookup = try #require(second.store.currentDeviceSyncLookupIdentity)
        let reselection = Task { @MainActor in
            await second.store.prepareDeviceSync(for: reselectionLookup)
        }
        await Task.yield()
        #expect(await server.currentLease(for: fixture.key) == nil)

        await server.resumePausedClaim()
        await stalePublish.value
        await reselection.value

        let currentIdentity = try #require(second.store.activeDeviceSyncIdentity)
        let currentClient = try #require(second.store.deviceSyncClient(for: currentIdentity))
        var didSettle = false
        for _ in 0 ..< 2000 {
            if second.store.deviceSyncState != .syncing,
               second.store.deviceSyncState != .forcing {
                didSettle = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(didSettle)
        let lease = try #require(await server.currentLease(for: fixture.key))
        let coordinatorState = await currentClient.coordinator.state
        let coordinatorContext = try #require({
            if case let .upToDate(context) = coordinatorState {
                return context
            }
            return nil
        }())
        #expect(second.store.deviceSyncState == .writer)
        #expect(second.store.deviceSyncTransferState == .upToDate)
        #expect(coordinatorContext.pendingRevisionCount == 0)
        #expect(coordinatorContext.remoteConfirmation == .confirmed)
        #expect(coordinatorContext.localHead.content == "second local edit")
        #expect(await server.currentHead(for: fixture.key)?.content == "second local edit")
        // D-060では再選択だけでauthorityをclaimし直さず、停止中の
        // 同じworking copy/clientのclaimをepochを進めず完了させる。
        #expect(lease.authority.epoch == 2)
        #expect(lease.authority.holderReplicaID == secondReplicaID)
        #expect(lease.authority.holderSessionID == currentClient.sessionID)
    }

    @Test("sync準備失敗はURL open・import・新規作成で迂回できない")
    func deviceSyncStartupFailureIsSticky() async throws {
        let fixture = try makeFixture(content: "protected")
        let app = try makeStore(
            fixture: fixture,
            server: InMemoryEpisodeSyncServer(),
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "protected.novelpkg"
        )
        let originalDocument = app.store.document
        let originalURL = app.store.documentURL
        let originalGeneration = app.store.documentSessionGeneration

        app.store.failStartupForDeviceSyncSafety()
        #expect(await !(app.store.makeNewDocument()))
        #expect(await !(app.store.importPackage(from: originalURL)))
        #expect(await !(app.store.handleExternalPackageURL(originalURL)))
        #expect(await !(app.store.openPrivateDocument(id: IOSPrivateDocumentID(packageName: "protected.novelpkg"))))
        app.store.install(
            NovelDocument.newDocument(title: "must not install"),
            at: originalURL,
            attachments: []
        )

        guard case .recovery = app.store.startupState else {
            Issue.record("Device Syncの安全停止がRecoveryになっていません。")
            return
        }
        #expect(app.store.document == originalDocument)
        #expect(app.store.documentURL == originalURL)
        #expect(app.store.documentSessionGeneration == originalGeneration)
        #expect(app.store.deviceSyncStartupFailedSafely)
    }

    @Test("別端末がremote writerでも実UITextViewをそのまま編集できる")
    func realTextViewRemainsEditableWhileAnotherDeviceIsRemoteWriter() async throws {
        let fixture = try makeFixture(content: "shared remote")
        let server = InMemoryEpisodeSyncServer()
        let writer = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "writer.novelpkg"
        )
        let follower = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "follower.novelpkg"
        )

        await prepareSelectedEpisode(in: writer.store)
        await prepareSelectedEpisode(in: follower.store)
        let writerToken = try #require(writer.store.currentEpisodeEditingToken)
        writer.store.updateEpisodeContent(
            "writer remote advance",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: writerToken
        )
        await writer.store.deviceSyncDraftTask?.value
        #expect(await server.currentHead(for: fixture.key)?.content == "writer remote advance")
        let followerLookup = try #require(follower.store.currentDeviceSyncLookupIdentity)
        #expect(follower.store.deviceSyncAllowsEditing(for: followerLookup))

        let harness = try await makeEditorHarness(store: follower.store)
        defer {
            follower.store.deviceSyncDraftTask?.cancel()
            follower.store.deviceSyncDraftTask = nil
            harness.cleanup()
        }
        #expect(harness.textView.isEditable)
        #expect(harness.textView.isSelectable)
        harness.textView.selectedRange = NSRange(location: 0, length: 6)
        #expect(harness.textView.selectedRange == NSRange(location: 0, length: 6))
        let epochBeforeEditing = await server.currentLeaseEpoch(for: fixture.key)

        harness.textView.copy(nil)
        await advanceMainRunLoop(iterations: 2)
        #expect(follower.store.deviceSyncAllowsEditing(for: followerLookup))
        #expect(await server.currentLeaseEpoch(for: fixture.key) == epochBeforeEditing)

        harness.textView.selectedRange = NSRange(
            location: (harness.textView.text as NSString).length,
            length: 0
        )
        #expect(harness.textView.isEditable)
        #expect(harness.textView.isFirstResponder)
        #expect(harness.textView.isUserInteractionEnabled)
        let insertionPoint = try #require(harness.textView.selectedTextRange)
        harness.textView.replace(insertionPoint, withText: "追")
        await advanceMainRunLoop(iterations: 2)
        #expect(harness.textView.text.hasSuffix("追"))

        harness.textView.deleteBackward()
        await advanceMainRunLoop(iterations: 2)
        #expect(harness.textView.text == "shared remote")

        harness.textView.undoManager?.undo()
        await advanceMainRunLoop(iterations: 2)
        #expect(harness.textView.text.hasSuffix("追"))
        harness.textView.undoManager?.redo()
        await advanceMainRunLoop(iterations: 2)
        #expect(harness.textView.text == "shared remote")

        harness.textView.selectedRange = NSRange(
            location: (harness.textView.text as NSString).length,
            length: 0
        )
        harness.textView.paste(itemProviders: [NSItemProvider(object: "貼付" as NSString)])
        for _ in 0 ..< 400 where !harness.textView.text.hasSuffix("貼付") {
            try await Task.sleep(for: .milliseconds(5))
            await advanceMainRunLoop()
        }
        #expect(harness.textView.text.hasSuffix("貼付"))

        harness.textView.selectedRange = (harness.textView.text as NSString).range(of: "shared")
        let rubyID = follower.store.editorCommandSession.requestSelectionSnapshot()
        for _ in 0 ..< 200 where follower.store.editorCommandSession.selectionSnapshot?.id != rubyID {
            await advanceMainRunLoop()
        }
        #expect(follower.store.editorCommandSession.selectionSnapshot?.id == rubyID)
        follower.store.editorCommandSession.replaceSelection(id: rubyID, text: "｜共有《きょうゆう》")
        for _ in 0 ..< 200 where !harness.textView.text.contains("｜共有《きょうゆう》") {
            await advanceMainRunLoop()
        }
        #expect(harness.textView.text.contains("｜共有《きょうゆう》"))

        harness.textView.selectedRange = (harness.textView.text as NSString).range(of: "remote")
        let boutenID = follower.store.editorCommandSession.requestSelectionSnapshot()
        for _ in 0 ..< 200 where follower.store.editorCommandSession.selectionSnapshot?.id != boutenID {
            await advanceMainRunLoop()
        }
        #expect(follower.store.editorCommandSession.selectionSnapshot?.id == boutenID)
        follower.store.editorCommandSession.replaceSelection(id: boutenID, text: "｜r《・》｜e《・》｜m《・》｜o《・》｜t《・》｜e《・》")
        for _ in 0 ..< 200 where !harness.textView.text.contains("｜r《・》｜e《・》") {
            await advanceMainRunLoop()
        }
        #expect(harness.textView.text.contains("｜r《・》｜e《・》"))

        #expect(follower.store.document.episode(fixture.episodeID)?.episode.content.hasSuffix("貼付") == true)
        #expect(follower.store.deviceSyncAllowsEditing(for: followerLookup))
        #expect(await server.currentLeaseEpoch(for: fixture.key) == epochBeforeEditing)
    }

    @Test("閲覧・refresh・再選択だけではauthorityをclaimせずlocal編集を継続できる")
    func cleanRefreshAndRevisitDoNotClaimAuthority() async throws {
        let fixture = try makeFixture(content: "shared")
        let server = InMemoryEpisodeSyncServer()
        let first = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "normal-handoff-first.novelpkg"
        )
        let second = try makeStore(
            fixture: fixture,
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replicaID: SyncReplicaID(),
            packageName: "normal-handoff-second.novelpkg"
        )

        await prepareSelectedEpisode(in: first.store)
        await prepareSelectedEpisode(in: second.store)
        #expect(first.store.deviceSyncState == .readOnly)
        #expect(second.store.deviceSyncState == .readOnly)
        #expect(await server.currentLease(for: fixture.key) == nil)
        let firstLookup = try #require(first.store.currentDeviceSyncLookupIdentity)
        let secondLookup = try #require(second.store.currentDeviceSyncLookupIdentity)
        #expect(first.store.deviceSyncAllowsEditing(for: firstLookup))
        #expect(second.store.deviceSyncAllowsEditing(for: secondLookup))

        let firstIdentity = try #require(first.store.activeDeviceSyncIdentity)
        let firstClient = try #require(first.store.deviceSyncClient(for: firstIdentity))
        _ = try await firstClient.coordinator.releaseEditingAuthority()

        await second.store.refreshSelectedEpisodeDeviceSync()
        #expect(second.store.deviceSyncState == .readOnly)
        #expect(await server.currentLease(for: fixture.key) == nil)

        let secondIdentity = try #require(second.store.activeDeviceSyncIdentity)
        let secondClient = try #require(second.store.deviceSyncClient(for: secondIdentity))
        _ = try await secondClient.coordinator.releaseEditingAuthority()

        first.store.deviceSyncSelectionDidChange()
        await prepareSelectedEpisode(in: first.store)
        #expect(first.store.deviceSyncState == .readOnly)
        #expect(await server.currentLease(for: fixture.key) == nil)
        let revisitedLookup = try #require(first.store.currentDeviceSyncLookupIdentity)
        #expect(first.store.deviceSyncAllowsEditing(for: revisitedLookup))
    }

    @Test("remote更新は実UITextViewのIME・選択・Undoを変えず確定後にlocal branchへ保存する")
    func remoteRefreshNeverInjectsIntoActiveTextView() async throws {
        let fixture = try makeFixture(content: "B remote")
        let server = InMemoryEpisodeSyncServer()
        let appJournal = InMemoryEpisodeSyncJournal()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: appJournal,
            replicaID: SyncReplicaID(),
            packageName: "ime-writer.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        let lookup = try #require(app.store.currentDeviceSyncLookupIdentity)
        #expect(app.store.deviceSyncAllowsEditing(for: lookup))
        let oldGeneration = app.store.editorContentGeneration

        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }
        harness.textView.selectedRange = NSRange(location: 0, length: 1)
        beginMarkedText("変換中", in: harness.textView)
        #expect(harness.textView.markedTextRange != nil)
        let textBeforeRefresh = harness.textView.text
        let selectionBeforeRefresh = harness.textView.selectedRange
        let undoBeforeRefresh = harness.textView.undoManager?.canUndo

        let other = EpisodeSyncCoordinator(
            key: fixture.key,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        let now = Date(timeIntervalSince1970: 20000)
        _ = try await other.link(
            localContent: fixture.content,
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        _ = try await other.claimEditingAuthority(expiresAt: now.addingTimeInterval(600))
        let grant = try await other.prepareForcedContinuation(expiresAt: now.addingTimeInterval(600))
        _ = try await other.confirmAuthorityInstall(
            grant,
            installedRemoteDigest: grant.snapshot.head?.contentDigest
        )
        _ = try await other.recordLocalContent("C new remote", createdAt: now.addingTimeInterval(1))
        _ = try await other.synchronize()

        await app.store.refreshSelectedEpisodeDeviceSync()
        await advanceMainRunLoop(iterations: 4)

        #expect(harness.textView.text == textBeforeRefresh)
        #expect(harness.textView.markedTextRange != nil)
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == fixture.content)
        #expect(app.store.editorContentGeneration == oldGeneration)
        #expect(harness.textView.selectedRange == selectionBeforeRefresh)
        #expect(harness.textView.undoManager?.canUndo == undoBeforeRefresh)
        #expect(harness.textView.isEditable)

        harness.textView.unmarkText()
        await advanceMainRunLoop(iterations: 4)
        #expect(harness.textView.markedTextRange == nil)
        #expect(harness.textView.text.contains("変換中"))
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content.contains("変換中") == true)
        await app.store.deviceSyncDraftTask?.value

        let record = try #require(await appJournal.storedRecord(for: fixture.key))
        #expect(record.localHead.content.contains("変換中"))
        #expect(record.conflict?.remote.content == "C new remote")
        #expect(harness.textView.text.contains("変換中"))
    }

    @Test("旧sealed再送後に残る最新tailも入力停止中に送信する")
    func publishRetriesTailAfterInterruptedSealedBatch() async throws {
        let fixture = try makeFixture(content: "initial")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "publish-tail.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        #expect(app.store.deviceSyncState == .readOnly)

        await server.cancelNextPublish()
        let firstToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "first sealed",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: firstToken
        )
        await app.store.deviceSyncDraftTask?.value
        let interrupted = try #require(await journal.storedRecord(for: fixture.key))
        #expect(interrupted.sealedPublish != nil)

        let latestToken = try #require(app.store.currentEpisodeEditingToken)
        app.store.updateEpisodeContent(
            "latest tail",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: latestToken
        )
        let latestDraft = try #require(app.store.deviceSyncDraftTask)
        await latestDraft.value

        let remote = try #require(await server.currentHead(for: fixture.key))
        let settled = try #require(await journal.storedRecord(for: fixture.key))
        #expect(remote.content == "latest tail")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(settled.sealedPublish == nil)
        #expect(app.store.deviceSyncTransferState == .upToDate)
    }

    @Test("通信停止中のbackground保存は実UITextViewのIME本文を先にpackageへ残す")
    func backgroundFlushDoesNotWaitForPausedPublish() async throws {
        let fixture = try makeFixture(content: "initial")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "background-ime.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        #expect(app.store.deviceSyncState == .readOnly)
        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }

        await server.pauseNextPublish()
        harness.textView.selectedRange = NSRange(
            location: (harness.textView.text as NSString).length,
            length: 0
        )
        harness.textView.insertText("送信中")
        var reachedPublish = false
        for _ in 0 ..< 2000 {
            if await server.publishIsPaused() {
                reachedPublish = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(reachedPublish)

        beginMarkedText("最新", in: harness.textView)
        #expect(harness.textView.markedTextRange != nil)
        let flush = Task { @MainActor in
            await app.store.flushDeviceSyncForBackground()
        }
        try await Task.sleep(for: .milliseconds(100))

        let savedBeforeNetworkResumed = try await app.repository.load(from: app.store.documentURL)
        #expect(savedBeforeNetworkResumed.episode(fixture.episodeID)?.episode.content == "initial送信中最新")
        #expect(harness.textView.markedTextRange == nil)
        let durableTail = try #require(await journal.storedRecord(for: fixture.key))
        #expect(durableTail.localHead.content == "initial送信中最新")
        #expect(durableTail.pendingRevisions.contains { $0.content == "initial送信中最新" })

        await server.resumePausedPublish()
        #expect(await flush.value)
        try await Task.sleep(for: .milliseconds(100))
        let retainedTail = try #require(await journal.storedRecord(for: fixture.key))
        #expect(retainedTail.localHead.content == "initial送信中最新")
    }

    @Test("packageだけ先行した本文はauthority再取得時にjournalとremoteへ反映する")
    func verifiedAuthorityReplaysPackageAheadContent() async throws {
        let fixture = try makeFixture(content: "R0")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "package-ahead.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        let identity = try #require(app.store.activeDeviceSyncIdentity)
        let client = try #require(app.store.deviceSyncClient(for: identity))
        let editingToken = try #require(app.store.currentEpisodeEditingToken)

        app.store.updateEpisodeContent(
            "X package ahead",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: editingToken
        )
        app.store.deviceSyncDraftTask?.cancel()
        app.store.deviceSyncDraftTask = nil
        #expect(await app.store.saveNow())
        let before = try #require(await journal.storedRecord(for: fixture.key))
        #expect(before.localHead.content == "R0")

        _ = try await client.coordinator.releaseEditingAuthority()
        await app.store.refreshSelectedEpisodeDeviceSync()

        let remote = try #require(await server.currentHead(for: fixture.key))
        let settled = try #require(await journal.storedRecord(for: fixture.key))
        #expect(remote.content == "X package ahead")
        #expect(settled.localHead.content == "X package ahead")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(app.store.deviceSyncState == .writer)
        #expect(app.store.deviceSyncTransferState == .upToDate)
    }

    @Test("停止中の古いfence応答は新しいdraft publishを巻き戻さない")
    func staleFenceResponseCannotRollBackDraftPublish() async throws {
        let fixture = try makeFixture(content: "R0")
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            packageName: "stale-fence-draft.novelpkg"
        )
        await prepareSelectedEpisode(in: app.store)
        let editingToken = try #require(app.store.currentEpisodeEditingToken)

        await server.pauseNextSnapshotResponseAfterCapture()
        let refresh = Task { @MainActor in
            await app.store.refreshSelectedEpisodeDeviceSync()
        }
        var reachedSnapshotPause = false
        for _ in 0 ..< 2000 {
            if await server.snapshotResponseIsPaused() {
                reachedSnapshotPause = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(reachedSnapshotPause)

        app.store.updateEpisodeContent(
            "R1",
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            expectedEditingToken: editingToken
        )
        let draft = try #require(app.store.deviceSyncDraftTask)
        for _ in 0 ..< 100 {
            if await journal.storedRecord(for: fixture.key)?.localHead.content == "R1" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let durableTail = try #require(await journal.storedRecord(for: fixture.key))
        #expect(durableTail.localHead.content == "R1")
        // clean openはremoteへ基準本文をpublishしない。
        #expect(await server.currentHead(for: fixture.key) == nil)

        await server.resumePausedSnapshotResponse()
        await refresh.value
        await draft.value

        let settled = try #require(await journal.storedRecord(for: fixture.key))
        #expect(await server.currentHead(for: fixture.key)?.content == "R1")
        #expect(settled.localHead.content == "R1")
        #expect(settled.pendingRevisions.isEmpty)
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "R1")
        #expect(app.store.deviceSyncState == .writer)
    }

    @Test("競合中の追加localとremote raceを保持した2-parent mergeだけを公開する")
    func conflictForceRacePreservesLatestLocalChain() async throws {
        let fixture = try makeFixture(content: "X package-only draft")
        let server = InMemoryEpisodeSyncServer()
        let writer = EpisodeSyncCoordinator(
            key: fixture.key,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryEpisodeSyncJournal()
        )
        let now = Date(timeIntervalSince1970: 30000)
        _ = try await writer.link(
            localContent: "B remote",
            createdAt: now,
            leaseExpiresAt: now.addingTimeInterval(600)
        )
        let remoteB = try #require(await server.currentHead(for: fixture.key))

        let appJournal = InMemoryEpisodeSyncJournal()
        let mergeRecoveryStore = IOSInMemoryDeviceSyncMergeRecoveryStore()
        let localWorkingCopyID = LocalWorkingCopyID()
        let localA = try EpisodeRevision(
            key: fixture.key,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            content: "A local fork",
            clientCreatedAt: now.addingTimeInterval(1)
        )
        try await appJournal.save(
            EpisodeSyncJournalRecord(
                key: fixture.key,
                localWorkingCopyID: localWorkingCopyID,
                branchID: localA.branchID,
                lastKnownRemoteHead: remoteB,
                localHead: localA,
                pendingRevisions: [localA],
                conflict: EpisodeConflict(base: nil, local: localA, remote: remoteB),
                mode: .forcedFork
            )
        )
        let app = try makeStore(
            fixture: fixture,
            server: server,
            journal: appJournal,
            replicaID: SyncReplicaID(),
            packageName: "conflict-race.novelpkg",
            mergeRecoveryStore: mergeRecoveryStore,
            localWorkingCopyID: localWorkingCopyID,
            now: { now.addingTimeInterval(10) }
        )
        await prepareSelectedEpisode(in: app.store)
        let presentedConflict = try #require(app.store.deviceSyncConflict)
        #expect(presentedConflict.local.content == "X package-only draft")
        #expect(presentedConflict.local.parentRevisionIDs == [localA.revisionID])
        #expect(presentedConflict.remote.revisionID == remoteB.revisionID)
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == "X package-only draft")
        #expect(app.store.pendingDeviceSyncConflictResolution == nil)

        _ = try await writer.recordLocalContent("C raced remote", createdAt: now.addingTimeInterval(2))
        _ = try await writer.synchronize()
        let remoteC = try #require(await server.currentHead(for: fixture.key))

        await app.store.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: presentedConflict
        )

        var observedRemoteRace = false
        for _ in 0 ..< 2000 {
            if app.store.deviceSyncConflict?.remote.revisionID == remoteC.revisionID {
                observedRemoteRace = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(observedRemoteRace)
        let rebasedConflict = try #require(app.store.deviceSyncConflict)
        #expect(rebasedConflict.local.content == presentedConflict.local.content)
        #expect(Set(rebasedConflict.local.parentRevisionIDs) == Set([
            presentedConflict.local.revisionID,
            remoteB.revisionID
        ]))
        #expect(rebasedConflict.remote.revisionID == remoteC.revisionID)
        #expect(app.store.pendingDeviceSyncConflictResolution?.content == presentedConflict.local.content)
        let rebasedLocalWorkingCopyID = try #require(
            app.store.activeDeviceSyncIdentity?.localWorkingCopyID
        )
        let loadedRebasedMarker = await mergeRecoveryStore.load(
            localWorkingCopyID: rebasedLocalWorkingCopyID,
            key: fixture.key
        )
        #expect(loadedRebasedMarker == nil)
        await server.pauseNextPublish()
        await app.store.resolveDeviceSyncConflict(
            using: .keepLocal,
            expectedConflict: rebasedConflict
        )
        var reachedPublish = false
        for _ in 0 ..< 2000 {
            if await server.publishIsPaused() {
                reachedPublish = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(reachedPublish)
        #expect(await mergeRecoveryStore.load(
            localWorkingCopyID: localWorkingCopyID,
            key: fixture.key
        ) == nil)

        #expect(await app.store.prepareForEditorSurfaceDeparture())
        await server.resumePausedPublish()
        var didPublishFinalMerge = false
        for _ in 0 ..< 2000 {
            let remote = await server.currentHead(for: fixture.key)
            let record = await appJournal.storedRecord(for: fixture.key)
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

        let mergedHead = try #require(await server.currentHead(for: fixture.key))
        #expect(mergedHead.content == presentedConflict.local.content)
        #expect(Set(mergedHead.parentRevisionIDs) == Set([
            rebasedConflict.local.revisionID,
            remoteC.revisionID
        ]))
        #expect(!mergedHead.parentRevisionIDs.contains(remoteB.revisionID))
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == presentedConflict.local.content)
        #expect(app.store.deviceSyncConflict == nil)
        let storedRecord = try #require(await appJournal.storedRecord(for: fixture.key))
        #expect(storedRecord.conflict == nil)
        #expect(storedRecord.localHead.revisionID == mergedHead.revisionID)
        #expect(storedRecord.pendingRevisions.isEmpty)
        #expect(storedRecord.stagedConflictResolution == nil)
        #expect(storedRecord.conflictResolutionRecovery == nil)
        #expect(await mergeRecoveryStore.load(
            localWorkingCopyID: localWorkingCopyID,
            key: fixture.key
        ) == nil)

        let relaunchedFixture = IOSDeviceSyncFixture(
            document: app.store.document,
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            key: fixture.key,
            structureDigest: fixture.structureDigest,
            content: presentedConflict.local.content
        )
        let relaunched = try makeStore(
            fixture: relaunchedFixture,
            server: server,
            journal: appJournal,
            replicaID: SyncReplicaID(),
            packageName: "conflict-race-relaunch.novelpkg",
            mergeRecoveryStore: mergeRecoveryStore,
            localWorkingCopyID: localWorkingCopyID,
            now: { now.addingTimeInterval(20) }
        )
        await prepareSelectedEpisode(in: relaunched.store)
        #expect(relaunched.store.pendingDeviceSyncConflictResolution == nil)
        #expect(relaunched.store.deviceSyncConflict == nil)
    }

    private func prepareSelectedEpisode(in store: IOSDocumentStore) async {
        guard let lookup = store.currentDeviceSyncLookupIdentity else {
            Issue.record("選択中の話にDevice Sync identityがありません。")
            return
        }
        await store.prepareDeviceSync(for: lookup)
    }

    private func makeStore(
        fixture: IOSDeviceSyncFixture,
        server: InMemoryEpisodeSyncServer,
        journal: InMemoryEpisodeSyncJournal,
        replicaID: SyncReplicaID,
        packageName: String,
        mergeRecoveryStore: any IOSDeviceSyncMergeRecoveryStoring = IOSInMemoryDeviceSyncMergeRecoveryStore(),
        localWorkingCopyID: LocalWorkingCopyID = LocalWorkingCopyID(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 10000) },
        remoteChangeSignals: AsyncStream<Void>? = nil,
        editIntentStore: any IOSDeviceSyncEditIntentStoring = IOSInMemoryDeviceSyncEditIntentStore(),
        binding: (@Sendable (
            IOSPrivateDocumentID,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> IOSDeviceSyncBindingResolution?)? = nil
    ) throws -> (store: IOSDocumentStore, repository: IOSDeviceSyncRepository) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-DeviceSync-Tests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(packageName, isDirectory: true)
        let repository = IOSDeviceSyncRepository(initialDocument: fixture.document, at: url)
        let resolution = IOSDeviceSyncBindingResolution(
            binding: SyncWorkingCopyBinding(
                localWorkingCopyID: localWorkingCopyID,
                workID: fixture.key.workID
            ),
            descriptor: SyncWorkDescriptor(
                workID: fixture.key.workID,
                sourceDocumentID: fixture.document.id,
                structureDigest: fixture.structureDigest,
                title: fixture.document.title
            ),
            journal: journal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id))
        )
        let runtime = IOSDeviceSyncRuntime(
            replicaID: replicaID,
            transport: server,
            binding: binding ?? { _, _, _ in resolution },
            remoteChangeSignals: remoteChangeSignals,
            mergeRecoveryStore: mergeRecoveryStore,
            editIntentStore: editIntentStore,
            now: now,
            leaseDuration: 600
        )
        let suiteName = "FUMINIWAIOS.DeviceSyncIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = IOSDocumentStore(
            repository: repository,
            userDefaults: defaults,
            deviceSyncRuntime: runtime,
            libraryRoot: root
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.install(fixture.document, at: url, attachments: [])
        store.startupState = .ready
        store.saveState = .saved
        return (store, repository)
    }

    private func makeFixture(content: String) throws -> IOSDeviceSyncFixture {
        let chapterID = ChapterID()
        let episodeID = EpisodeID()
        let document = NovelDocument(
            title: "sync fixture",
            chapters: [
                Chapter(
                    id: chapterID,
                    title: "chapter",
                    episodes: [Episode(id: episodeID, content: content)]
                )
            ]
        )
        return try IOSDeviceSyncFixture(
            document: document,
            chapterID: chapterID,
            episodeID: episodeID,
            key: EpisodeSyncKey(workID: SyncWorkID(), episodeID: episodeID),
            structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
            content: content
        )
    }

    private func makeTwoChapterFixture(
        title: String,
        firstContent: String,
        secondContent: String
    ) throws -> IOSDeviceSyncFixture {
        let firstEpisode = Episode(content: firstContent)
        let document = NovelDocument(
            title: title,
            chapters: [
                Chapter(title: "first", episodes: [firstEpisode]),
                Chapter(title: "second", episodes: [Episode(content: secondContent)])
            ]
        )
        return try IOSDeviceSyncFixture(
            document: document,
            chapterID: document.chapters[0].id,
            episodeID: firstEpisode.id,
            key: EpisodeSyncKey(workID: SyncWorkID(), episodeID: firstEpisode.id),
            structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
            content: firstContent
        )
    }

    private func makeEditorHarness(store: IOSDocumentStore) async throws -> IOSDeviceSyncEditorHarness {
        let host = UIHostingController(rootView: IOSEditorPane(store: store))
        let frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()

        for _ in 0 ..< 32 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if let textView = findTextView(in: host.view) {
                _ = textView.becomeFirstResponder()
                await advanceMainRunLoop()
                guard textView.window === window,
                      textView.isFirstResponder,
                      store.editorCommandSession.hasActiveEditorSurface else { continue }
                return IOSDeviceSyncEditorHarness(window: window, host: host, textView: textView)
            }
            await advanceMainRunLoop()
        }
        window.isHidden = true
        window.rootViewController = nil
        throw IOSDeviceSyncTestError.textViewNotFound
    }

    private func beginMarkedText(_ text: String, in textView: UITextView) {
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
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
    ) -> IOSDeviceSyncEditIntentMarker {
        IOSDeviceSyncEditIntentMarker(
            protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
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

    private func advanceMainRunLoop(iterations: Int = 1) async {
        for _ in 0 ..< iterations {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform {
                    continuation.resume()
                }
            }
        }
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}

private struct IOSDeviceSyncFixture {
    let document: NovelDocument
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let key: EpisodeSyncKey
    let structureDigest: SyncWorkStructureDigest
    let content: String
}

@MainActor
private struct IOSDeviceSyncEditorHarness {
    let window: UIWindow
    let host: UIHostingController<IOSEditorPane>
    let textView: UITextView

    func cleanup() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private actor IOSDeviceSyncRepository: DocumentCopyingRepository {
    private var documents: [String: NovelDocument]
    private var saveObserver: (@Sendable (NovelDocument) async -> Void)?
    private var shouldPauseNextSave = false
    private var pausedSaveContinuation: CheckedContinuation<Void, Never>?

    init(initialDocument: NovelDocument, at url: URL) {
        documents = [url.standardizedFileURL.path: initialDocument]
    }

    func load(from url: URL) async throws -> NovelDocument {
        guard let document = documents[url.standardizedFileURL.path] else {
            throw IOSDeviceSyncTestError.missingDocument
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

    func saveCopy(_ document: NovelDocument, from _: URL, to destinationURL: URL) async throws {
        documents[destinationURL.standardizedFileURL.path] = document
    }

    func setSaveObserver(_ observer: (@Sendable (NovelDocument) async -> Void)?) {
        saveObserver = observer
    }
}

private actor IOSConfirmFailureSaveObserver {
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

private actor IOSDelayedDeviceSyncBindingResolver {
    private var lookupCount = 0
    private var continuation: CheckedContinuation<IOSDeviceSyncBindingResolution?, Never>?

    func resolve() async -> IOSDeviceSyncBindingResolution? {
        lookupCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilLookupIsPaused() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume(with resolution: IOSDeviceSyncBindingResolution?) {
        continuation?.resume(returning: resolution)
        continuation = nil
    }

    func observedLookupCount() -> Int {
        lookupCount
    }
}

private actor IOSStaleDeviceSyncBindingResolver {
    private var lookupCount = 0
    private var firstContinuation: CheckedContinuation<IOSDeviceSyncBindingResolution?, Never>?

    func resolve() async -> IOSDeviceSyncBindingResolution? {
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

    func resumeFirstLookup(with resolution: IOSDeviceSyncBindingResolution?) {
        firstContinuation?.resume(returning: resolution)
        firstContinuation = nil
    }

    func observedLookupCount() -> Int {
        lookupCount
    }
}

private actor IOSLocalFirstBindingSequenceResolver {
    private let initial: IOSDeviceSyncBindingResolution
    private let subsequent: IOSDeviceSyncBindingResolution
    private var observedLookups = 0
    private var initialContinuation: CheckedContinuation<IOSDeviceSyncBindingResolution, Never>?

    init(
        initial: IOSDeviceSyncBindingResolution,
        subsequent: IOSDeviceSyncBindingResolution
    ) {
        self.initial = initial
        self.subsequent = subsequent
    }

    func resolve() async throws -> IOSDeviceSyncBindingResolution {
        observedLookups += 1
        guard observedLookups == 1 else { return subsequent }
        return await withCheckedContinuation { continuation in
            initialContinuation = continuation
        }
    }

    func waitUntilInitialLookupIsPaused() async {
        while initialContinuation == nil {
            await Task.yield()
        }
    }

    func resumeInitialLookup() {
        initialContinuation?.resume(returning: initial)
        initialContinuation = nil
    }

    func lookupCount() -> Int {
        observedLookups
    }
}

private actor IOSPausableDeviceSyncEditIntentStore: IOSDeviceSyncEditIntentStoring {
    private let storage = IOSInMemoryDeviceSyncEditIntentStore()
    private var storedScope: (workingCopyIdentity: String, documentID: UUID, episodeID: EpisodeID)?
    private var shouldPauseLoad = false
    private var loadContinuation: CheckedContinuation<Void, Never>?

    func seed(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        _ = try await storage.save(
            marker,
            baselinePackageDigest: marker.baseContentDigest ?? marker.contentDigest
        )
        storedScope = (marker.workingCopyIdentity, marker.documentID, marker.episodeID)
    }

    func pauseNextLoad() {
        shouldPauseLoad = true
    }

    func save(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try await storage.save(marker)
    }

    func save(
        _ marker: IOSDeviceSyncEditIntentMarker,
        baselinePackageDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncEditIntentMarker {
        try await storage.save(marker, baselinePackageDigest: baselinePackageDigest)
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [IOSDeviceSyncEditIntentMarker] {
        try await storage.load(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func remove(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try await storage.remove(marker)
    }

    func preparePackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try await storage.preparePackageSave(checkpoint)
    }

    func commitPackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try await storage.commitPackageSave(checkpoint)
    }

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        if shouldPauseLoad {
            shouldPauseLoad = false
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return try await storage.loadPersistenceSnapshot(
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
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        let snapshot = try await storage.reconcilePreparedPackage(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            actualContentDigest: actualContentDigest
        )
        // The marker becomes visible after local preflight, while the later
        // binding/journal preparation is suspended. Live IME input must win.
        return IOSDeviceSyncLocalPersistenceSnapshot(
            marker: nil,
            preservedMarkers: snapshot.preservedMarkers,
            committedPackage: snapshot.committedPackage,
            preparedPackage: snapshot.preparedPackage
        )
    }

    func acknowledgeLocalEditIntent(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        throughSequence: UInt64,
        contentDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        try await storage.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            throughSequence: throughSequence,
            contentDigest: contentDigest
        )
    }

    func preserveForReview(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try await storage.preserveForReview(marker)
    }

    func removePreservedForReview(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID,
        expected: [IOSDeviceSyncEditIntentMarker],
        expectedResolvingMarker: IOSDeviceSyncEditIntentMarker
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        try await storage.removePreservedForReview(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            expected: expected,
            expectedResolvingMarker: expectedResolvingMarker
        )
    }

    func waitUntilLoadIsPaused() async -> Bool {
        for _ in 0 ..< 2000 {
            if loadContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resumePausedLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func markers() async -> [IOSDeviceSyncEditIntentMarker] {
        guard let storedScope else { return [] }
        return await (try? storage.load(
            workingCopyIdentity: storedScope.workingCopyIdentity,
            documentID: storedScope.documentID,
            episodeID: storedScope.episodeID
        )) ?? []
    }
}

private actor IOSPausablePreservedRemovalDeviceSyncEditIntentStore: IOSDeviceSyncEditIntentStoring {
    private let storage = IOSInMemoryDeviceSyncEditIntentStore()
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

    func save(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try await storage.save(marker)
    }

    func save(
        _ marker: IOSDeviceSyncEditIntentMarker,
        baselinePackageDigest: SyncContentDigest
    ) async throws -> IOSDeviceSyncEditIntentMarker {
        try await storage.save(marker, baselinePackageDigest: baselinePackageDigest)
    }

    func load(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> [IOSDeviceSyncEditIntentMarker] {
        try await storage.load(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
    }

    func remove(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        try await storage.remove(marker)
    }

    func preparePackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try await storage.preparePackageSave(checkpoint)
    }

    func commitPackageSave(_ checkpoint: IOSDeviceSyncPackageCheckpoint) async throws {
        try await storage.commitPackageSave(checkpoint)
    }

    func loadPersistenceSnapshot(
        workingCopyIdentity: String,
        documentID: UUID,
        episodeID: EpisodeID
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
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
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
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
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
        try await storage.acknowledgeLocalEditIntent(
            workingCopyIdentity: workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID,
            throughSequence: throughSequence,
            contentDigest: contentDigest
        )
    }

    func preserveForReview(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
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
        expected: [IOSDeviceSyncEditIntentMarker],
        expectedResolvingMarker: IOSDeviceSyncEditIntentMarker
    ) async throws -> IOSDeviceSyncLocalPersistenceSnapshot {
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

private actor IOSFailingDeviceSyncEditIntentStore: IOSDeviceSyncEditIntentStoring {
    private var stored: [IOSDeviceSyncEditIntentMarker] = []
    private var remainingSaveFailures = 0
    private var alwaysFailsSave = false

    func seed(_ marker: IOSDeviceSyncEditIntentMarker) {
        stored = [marker]
    }

    func failNextSaves(_ count: Int) {
        remainingSaveFailures = count
    }

    func failAllSaves() {
        alwaysFailsSave = true
    }

    func save(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        if alwaysFailsSave || remainingSaveFailures > 0 {
            if remainingSaveFailures > 0 {
                remainingSaveFailures -= 1
            }
            throw IOSDeviceSyncTestError.injectedEditIntentFailure
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
    ) async throws -> [IOSDeviceSyncEditIntentMarker] {
        stored.filter {
            $0.workingCopyIdentity == workingCopyIdentity
                && $0.documentID == documentID
                && $0.episodeID == episodeID
        }
    }

    func remove(_ marker: IOSDeviceSyncEditIntentMarker) async throws {
        stored.removeAll { $0 == marker }
    }

    func markers() -> [IOSDeviceSyncEditIntentMarker] {
        stored
    }
}

private enum IOSDeviceSyncTestError: Error {
    case injectedEditIntentFailure
    case missingDocument
    case textViewNotFound
}
