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

    @Test("作品保存後の再接続はactive editorを変えずに自動追送する")
    func wholeWorkReconnectPublishesWithoutInjectingActiveEditor() async throws {
        let fixture = try makeFixture(content: "編集中の本文")
        let workServer = InMemoryWorkSyncServer()
        let appTransport = IOSAvailabilityControlledWorkSyncTransport(base: workServer)
        let journal = InMemoryWorkSyncJournal()
        let replicaID = SyncReplicaID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: appTransport,
            journal: journal,
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-active-editor.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }
        let mountedText = harness.textView.text

        let callsBeforeEdit = await appTransport.callCount()
        await appTransport.pauseNextRequestThenFail()
        app.store.updateDocumentTitle("地下鉄で変更した題名")
        #expect(await app.store.saveNow())
        await appTransport.waitUntilRequestIsPaused()
        let demandBeforeRefresh = app.store.workSyncNetworkDemandGeneration
        let refresh = Task { @MainActor in
            await app.store.refreshOrPrepareWorkDeviceSync()
        }
        for _ in 0 ..< 2000 {
            if app.store.workSyncNetworkDemandGeneration > demandBeforeRefresh {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(app.store.workSyncNetworkDemandGeneration > demandBeforeRefresh)
        await appTransport.resumePausedRequest()
        await refresh.value

        var uploaded: WorkRevision?
        for _ in 0 ..< 2000 {
            uploaded = await workServer.currentHead(for: fixture.key.workID)
            if uploaded?.snapshot.title == "地下鉄で変更した題名" {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(uploaded?.snapshot.title == "地下鉄で変更した題名")
        #expect(await appTransport.callCount() >= callsBeforeEdit + 2)
        #expect(harness.textView.text == mountedText)
        #expect(app.store.document.episode(fixture.episodeID)?.episode.content == mountedText)
    }

    @Test("作品の自動統合はactive editorへ注入せずsafe boundaryで反映する")
    func wholeWorkAutomaticMergeMaterializesOnlyAtSafeBoundary() async throws {
        let fixture = try makeFixture(content: "編集中の本文")
        let workServer = InMemoryWorkSyncServer()
        let appTransport = IOSAvailabilityControlledWorkSyncTransport(base: workServer)
        let remoteCoordinator = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: workServer,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await remoteCoordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: fixture.document),
            at: Date(timeIntervalSince1970: 8000)
        )
        _ = try await remoteCoordinator.synchronize(at: Date(timeIntervalSince1970: 8001))
        let sharedBase = try #require(await workServer.currentHead(for: fixture.key.workID))

        let localJournal = InMemoryWorkSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let localReplicaID = SyncReplicaID()
        let localBootstrap = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: localReplicaID,
            sessionID: SyncEditSessionID(),
            transport: workServer,
            journal: localJournal
        )
        _ = try await localBootstrap.bootstrapRemoteRevision(sharedBase)
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: appTransport,
            journal: localJournal,
            replicaID: localReplicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-auto-merge.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }
        let mountedText = harness.textView.text

        await appTransport.setOnline(false)
        app.store.updateDocumentTitle("このiPhoneの題名")
        #expect(await app.store.saveNow())
        for _ in 0 ..< 2000 {
            if app.store.workSyncNetworkTask == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(app.store.workSyncNetworkTask == nil)
        var remoteDocument = fixture.document
        remoteDocument.synopsis = "iCloudで変更したあらすじ"
        let remoteStage = try await remoteCoordinator.stageLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 8010)
        )
        try await remoteCoordinator.confirmLocalSnapshotMaterialized(
            remoteStage.revisionID,
            packageSnapshot: remoteStage.snapshot
        )
        _ = try await remoteCoordinator.synchronize(at: Date(timeIntervalSince1970: 8011))
        #expect(await workServer.currentHead(for: fixture.key.workID)?.snapshot.synopsis == "iCloudで変更したあらすじ")
        await appTransport.setOnline(true)

        await app.store.refreshOrPrepareWorkDeviceSync()
        let client = try #require(app.store.workSyncClient)
        let state = try await client.coordinator.currentState()
        let pending = try #require(state.pendingRemoteMaterialization)
        #expect(pending.kind == .automaticMerge)
        #expect(app.store.document.title == "このiPhoneの題名")
        #expect(app.store.document.synopsis == fixture.document.synopsis)
        #expect(harness.textView.text == mountedText)

        #expect(await app.store.flushDeviceSyncForBackground())
        #expect(app.store.document.title == "このiPhoneの題名")
        #expect(app.store.document.synopsis == "iCloudで変更したあらすじ")
        #expect(harness.textView.text == mountedText)
    }

    @Test("Editor外の未debounce作品情報を端末保存してからremoteを統合する")
    func wholeWorkFlushesUnsavedMetadataBeforeRemoteMaterialization() async throws {
        let fixture = try makeFixture(content: "本文")
        let workServer = InMemoryWorkSyncServer()
        let remoteCoordinator = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: workServer,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await remoteCoordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: fixture.document),
            at: Date(timeIntervalSince1970: 8050)
        )
        _ = try await remoteCoordinator.synchronize(at: Date(timeIntervalSince1970: 8051))
        let sharedBase = try #require(await workServer.currentHead(for: fixture.key.workID))
        let localJournal = InMemoryWorkSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let localReplicaID = SyncReplicaID()
        let localBootstrap = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: localReplicaID,
            sessionID: SyncEditSessionID(),
            transport: workServer,
            journal: localJournal
        )
        _ = try await localBootstrap.bootstrapRemoteRevision(sharedBase)
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workServer: workServer,
            journal: localJournal,
            replicaID: localReplicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-unsaved-metadata.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()

        var remoteDocument = fixture.document
        remoteDocument.synopsis = "iCloudで変更したあらすじ"
        let remoteStage = try await remoteCoordinator.stageLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 8052)
        )
        try await remoteCoordinator.confirmLocalSnapshotMaterialized(
            remoteStage.revisionID,
            packageSnapshot: remoteStage.snapshot
        )
        _ = try await remoteCoordinator.synchronize(at: Date(timeIntervalSince1970: 8053))

        // 2秒debounceを待たずにforeground/push相当の同期を開始する。
        app.store.updateDocumentTitle("地下鉄で未保存の題名")
        await app.store.refreshOrPrepareWorkDeviceSync()

        let package = try await app.repository.load(from: app.store.documentURL)
        #expect(app.store.document.title == "地下鉄で未保存の題名")
        #expect(app.store.document.synopsis == "iCloudで変更したあらすじ")
        #expect(package.title == "地下鉄で未保存の題名")
        #expect(package.synopsis == "iCloudで変更したあらすじ")
        let client = try #require(app.store.workSyncClient)
        let state = try await client.coordinator.currentState()
        #expect(state.stagedLocalRevision == nil)
        #expect(state.localHead.snapshot.title == "地下鉄で未保存の題名")
        #expect(state.localHead.snapshot.synopsis == "iCloudで変更したあらすじ")
    }

    @Test("作品同期中の連続編集はCAS retry枯渇後も入力停止後に自動追送する")
    func wholeWorkContinuousEditsRescheduleAfterLocalPending() async throws {
        let fixture = try makeFixture(content: "編集中の本文")
        let baseServer = InMemoryWorkSyncServer()
        let transport = IOSDivergingWorkSyncTransport(base: baseServer)
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: transport,
            journal: InMemoryWorkSyncJournal(),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-continuous-edits.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        let harness = try await makeEditorHarness(store: app.store)
        defer { harness.cleanup() }
        let mountedText = harness.textView.text

        await transport.divergeNextPublishes(4)
        await transport.pauseNextPublish()
        app.store.updateDocumentTitle("送信中の題名")
        #expect(await app.store.saveNow())
        await transport.waitUntilPublishIsPaused()

        app.store.updateDocumentTitle("入力停止時の最新題名")
        #expect(await app.store.saveNow())
        await transport.resumePausedPublish()

        var uploaded: WorkRevision?
        for _ in 0 ..< 2000 {
            uploaded = await baseServer.currentHead(for: fixture.key.workID)
            if uploaded?.snapshot.title == "入力停止時の最新題名" {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(uploaded?.snapshot.title == "入力停止時の最新題名")
        #expect(harness.textView.text == mountedText)
    }

    @Test("作品journal失敗でもpackageは保存しremote送信しない")
    func wholeWorkJournalFailureKeepsPackageAndSkipsRemote() async throws {
        let fixture = try makeFixture(content: "本文")
        let workServer = InMemoryWorkSyncServer()
        await workServer.setOnline(false)
        let journal = IOSFailingOnceWorkSyncJournal()
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workServer: workServer,
            journal: journal,
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-journal-failure.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        await journal.failNextSave()
        app.store.updateDocumentTitle("端末には保存する")

        #expect(await app.store.saveNow())
        let package = try await app.repository.load(from: app.store.documentURL)
        #expect(package.title == "端末には保存する")
        #expect(app.store.saveState == .saved)
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)
        #expect(await workServer.currentHead(for: fixture.key.workID) == nil)
        let status = IOSDeviceSyncStatusControl(
            saveState: app.store.saveState,
            state: app.store.deviceSyncState,
            transferState: app.store.deviceSyncTransferState,
            localDurabilityState: app.store.deviceSyncLocalDurabilityState,
            hasLocalRecoveryReview: false,
            isLocalRecoveryReviewReady: true,
            usesWholeWorkSync: true,
            reviewChanges: {}
        )
        #expect(status.resolvedStatus == .syncPreparationError)
    }

    @Test("作品同期の準備前でも同期上限を超える本文はpackageへexact保存する")
    func wholeWorkOversizedContentSavesBeforeActiveIdentity() async throws {
        let fixture = try makeFixture(content: "本文")
        let transport = IOSCountingWorkSyncTransport(base: InMemoryWorkSyncServer())
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: transport,
            journal: InMemoryWorkSyncJournal(),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-oversized-before-identity.novelpkg"
        )
        let oversizedContent = String(
            repeating: "a",
            count: WorkSnapshot.maximumStringUTF8Bytes + 1
        )

        #expect(app.store.activeWorkSyncIdentity == nil)
        app.store.updateEpisodeContent(
            oversizedContent,
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID
        )
        #expect(await app.store.saveNow())

        let package = try await app.repository.load(from: app.store.documentURL)
        #expect(package == app.store.document)
        #expect(package.episode(fixture.episodeID)?.episode.content == oversizedContent)
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)
        #expect(await transport.callCount() == 0)
    }

    @Test("作品同期の準備後も同期上限を超える本文はpackageへexact保存する")
    func wholeWorkOversizedContentSavesWithActiveIdentity() async throws {
        let fixture = try makeFixture(content: "本文")
        let transport = IOSCountingWorkSyncTransport(base: InMemoryWorkSyncServer())
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: transport,
            journal: InMemoryWorkSyncJournal(),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-oversized-with-identity.novelpkg",
            remoteBinding: { _, _, _ in nil }
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        let oversizedContent = String(
            repeating: "a",
            count: WorkSnapshot.maximumStringUTF8Bytes + 1
        )

        #expect(app.store.activeWorkSyncIdentity != nil)
        #expect(await transport.callCount() == 0)
        app.store.updateEpisodeContent(
            oversizedContent,
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID
        )
        #expect(await app.store.saveNow())

        let package = try await app.repository.load(from: app.store.documentURL)
        #expect(package == app.store.document)
        #expect(package.episode(fixture.episodeID)?.episode.content == oversizedContent)
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)
        #expect(await transport.callCount() == 0)
    }

    @Test("作品同期はpackage保存完了前にnetworkを開始しない")
    func wholeWorkNeverStartsNetworkBeforePackageSave() async throws {
        let fixture = try makeFixture(content: "本文")
        let baseServer = InMemoryWorkSyncServer()
        let orderProbe = IOSWorkSyncPackageOrderProbe()
        let transport = IOSPackageOrderedWorkSyncTransport(
            base: baseServer,
            probe: orderProbe
        )
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: transport,
            journal: InMemoryWorkSyncJournal(),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-package-before-network.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        await app.repository.setSaveObserver { _ in
            await orderProbe.recordPackageSave()
        }
        await orderProbe.beginObservation()

        app.store.updateDocumentTitle("package確定後に送る")
        #expect(await app.store.saveNow())
        for _ in 0 ..< 2000 {
            if await baseServer.currentHead(for: fixture.key.workID)?.snapshot.title == "package確定後に送る" {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await orderProbe.networkCallCount() > 0)
        #expect(await orderProbe.observedNetworkBeforePackage() == false)
    }

    @Test("pending remote中のstage失敗はpackage-only編集を上書きしない")
    func wholeWorkStageFailureFencesPendingRemoteMaterialization() async throws {
        try await verifyWorkJournalFailureFencesPendingRemote(failAfterSuccessfulSaves: 0)
    }

    @Test("pending remote中のconfirm失敗はpackage-only編集を上書きしない")
    func wholeWorkConfirmFailureFencesPendingRemoteMaterialization() async throws {
        try await verifyWorkJournalFailureFencesPendingRemote(failAfterSuccessfulSaves: 1)
    }

    @Test("競合選択前のstage失敗はpackage-only tailと旧reviewを保持する")
    func wholeWorkStageFailureFencesStaleConflictChoice() async throws {
        try await verifyWorkJournalFailureFencesConflictChoice(failAfterSuccessfulSaves: 0)
    }

    @Test("競合選択前のconfirm失敗はpackage-only tailと旧reviewを保持する")
    func wholeWorkConfirmFailureFencesStaleConflictChoice() async throws {
        try await verifyWorkJournalFailureFencesConflictChoice(failAfterSuccessfulSaves: 1)
    }

    @Test("再起動時に曖昧な端末内作品版を比較して選択後だけ編集を再開する")
    func wholeWorkLocalRecoveryRequiresExplicitChoiceAfterRelaunch() async throws {
        let fixture = try makeFixture(content: "共通本文")
        let workServer = InMemoryWorkSyncServer()
        await workServer.setOnline(false)
        let journal = InMemoryWorkSyncJournal()
        let replicaID = SyncReplicaID()
        let localWorkingCopyID = LocalWorkingCopyID()
        let first = try makeWholeWorkStore(
            fixture: fixture,
            workServer: workServer,
            journal: journal,
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-recovery.novelpkg"
        )
        await first.store.refreshOrPrepareWorkDeviceSync()
        let identity = try #require(first.store.activeWorkSyncIdentity)
        let client = try #require(first.store.workSyncClient)
        var stagedDocument = fixture.document
        stagedDocument.title = "保存直前の版"
        _ = try await client.coordinator.stageLocalSnapshot(
            WorkSnapshot(document: stagedDocument),
            at: Date(timeIntervalSince1970: 20000)
        )
        #expect(first.store.workSyncContextIsCurrent(identity))

        var packageDocument = fixture.document
        packageDocument.title = "パッケージに残った別の版"
        let relaunchedFixture = IOSDeviceSyncFixture(
            document: packageDocument,
            chapterID: fixture.chapterID,
            episodeID: fixture.episodeID,
            key: fixture.key,
            structureDigest: fixture.structureDigest,
            content: fixture.content
        )
        let relaunched = try makeWholeWorkStore(
            fixture: relaunchedFixture,
            workServer: workServer,
            journal: journal,
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-recovery.novelpkg"
        )
        await relaunched.store.refreshOrPrepareWorkDeviceSync()

        let recovery = try #require(relaunched.store.workSyncLocalRecoveryReview)
        let comparison = IOSWorkLocalRecoveryPresentation(review: recovery)
        #expect(relaunched.store.deviceSyncLocalRecoveryPending)
        #expect(comparison.presentation.local.summary(for: .title)?.detail == "「パッケージに残った別の版」")
        #expect(comparison.presentation.remote.summary(for: .title)?.detail == "「保存直前の版」")
        relaunched.store.workDeviceSyncSelectionDidChange()
        #expect(relaunched.store.deviceSyncLocalRecoveryPending)
        #expect(relaunched.store.workSyncLocalRecoveryReview == recovery)

        await relaunched.store.resolveWorkSyncLocalRecovery(
            using: .keepRemote,
            expectedReview: recovery
        )
        #expect(relaunched.store.document.title == "保存直前の版")
        #expect(relaunched.store.workSyncLocalRecoveryReview == nil)
        #expect(relaunched.store.deviceSyncLocalRecoveryPending == false)
    }

    @Test("local preflight復旧中は作品機能の編集を通さず旧snapshotで上書きしない")
    func wholeWorkPreflightSerializesProjectMutationWithRecovery() async throws {
        let fixture = try makeFixture(content: "本文")
        let server = InMemoryWorkSyncServer()
        let remote = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await remote.bootstrapLocalSnapshot(
            WorkSnapshot(document: fixture.document),
            at: Date(timeIntervalSince1970: 8060)
        )
        _ = try await remote.synchronize(at: Date(timeIntervalSince1970: 8061))
        let sharedBase = try #require(await server.currentHead(for: fixture.key.workID))
        let seedJournal = InMemoryWorkSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let localReplicaID = SyncReplicaID()
        let seed = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: localReplicaID,
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: seedJournal
        )
        _ = try await seed.bootstrapRemoteRevision(sharedBase)
        var remoteDocument = fixture.document
        remoteDocument.synopsis = "復旧対象のiCloud版"
        let remoteStage = try await remote.stageLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 8062)
        )
        try await remote.confirmLocalSnapshotMaterialized(
            remoteStage.revisionID,
            packageSnapshot: remoteStage.snapshot
        )
        _ = try await remote.synchronize(at: Date(timeIntervalSince1970: 8063))
        _ = try await seed.synchronize(at: Date(timeIntervalSince1970: 8064))
        let record = try #require(await seedJournal.storedRecord(for: fixture.key.workID))
        let journal = IOSPausableLoadWorkSyncJournal(record: record)
        await journal.pauseNextLoad()
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: server,
            journal: journal,
            replicaID: localReplicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-preflight-serialized.novelpkg"
        )

        let preparation = Task { @MainActor in
            await app.store.refreshOrPrepareWorkDeviceSync()
        }
        for _ in 0 ..< 2000 {
            if await journal.isLoadPaused() {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await journal.isLoadPaused())
        #expect(app.store.isDocumentTransitionInProgress)
        let session = try #require(app.store.currentDocumentSessionToken)
        #expect(app.store.addCharacter(name: "復旧中には追加しない", expectedSession: session) == nil)

        await journal.resumeLoad()
        await preparation.value
        #expect(app.store.isDocumentTransitionInProgress == false)
        #expect(app.store.document.synopsis == "復旧対象のiCloud版")
        #expect(app.store.document.characters.isEmpty)
        #expect(app.store.addCharacter(name: "復旧後の人物", expectedSession: session) != nil)
        #expect(await app.store.saveNow())
        #expect(try await app.repository.load(from: app.store.documentURL).characters.map(\.name) == ["復旧後の人物"])
    }

    @Test("作品競合の選択はpackageとjournalの一時失敗後も比較画面から再試行できる")
    func wholeWorkConflictChoiceRetriesExactPendingRevision() async throws {
        let fixture = try makeFixture(content: "共通本文")
        let workServer = InMemoryWorkSyncServer()
        let remoteJournal = InMemoryWorkSyncJournal()
        var remoteDocument = fixture.document
        remoteDocument.title = "iCloudにある題名"
        let remoteCoordinator = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: workServer,
            journal: remoteJournal
        )
        _ = try await remoteCoordinator.bootstrapLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 9000)
        )
        _ = try await remoteCoordinator.synchronize(at: Date(timeIntervalSince1970: 9001))

        let journal = IOSFailingOnceWorkSyncJournal()
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workServer: workServer,
            journal: journal,
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-conflict-retry.novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        let review = try #require(app.store.workSyncConflictReview)

        await app.repository.failNextSave(matchingTitle: remoteDocument.title)
        await app.store.resolveWorkSyncConflict(using: .keepRemote, expectedReview: review)
        #expect(app.store.workSyncConflictReview?.id == review.id)
        #expect(app.store.deviceSyncState == .needsReview)
        #expect(app.store.document.title == fixture.document.title)
        #expect(app.store.operationErrorMessage?.contains("再試行") == true)

        await app.store.resolveWorkSyncConflict(using: .keepLocal, expectedReview: review)
        #expect(app.store.workSyncConflictReview?.id == review.id)
        #expect(app.store.document.title == fixture.document.title)
        #expect(app.store.operationErrorMessage?.contains("前回選んだ「iCloudの版」") == true)

        await journal.failNextSave()
        await app.store.resolveWorkSyncConflict(using: .keepRemote, expectedReview: review)
        #expect(app.store.workSyncConflictReview?.id == review.id)
        #expect(app.store.deviceSyncState == .needsReview)
        #expect(app.store.document.title == remoteDocument.title)

        await app.store.resolveWorkSyncConflict(using: .keepLocal, expectedReview: review)
        #expect(app.store.workSyncConflictReview?.id == review.id)
        #expect(app.store.document.title == remoteDocument.title)
        #expect(app.store.operationErrorMessage?.contains("前回選んだ「iCloudの版」") == true)

        await app.store.resolveWorkSyncConflict(using: .keepRemote, expectedReview: review)
        #expect(app.store.workSyncConflictReview == nil)
        #expect(app.store.document.title == remoteDocument.title)
        #expect(try await app.repository.load(from: app.store.documentURL).title == remoteDocument.title)
    }

    @Test("作品同期の設定不一致やjournal欠落は端末編集を止めずnetworkを呼ばない")
    func wholeWorkPreflightFailureContinuesPackageOnlyEditing() async throws {
        let fixture = try makeFixture(content: "本文")
        let episodeJournal = InMemoryEpisodeSyncJournal()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: fixture.key.workID
        )
        let bindingCounter = IOSAsyncInvocationCounter()
        let transportCounter = IOSCountingWorkSyncTransport(base: InMemoryWorkSyncServer())
        let missingJournal = IOSDeviceSyncBindingResolution(
            binding: binding,
            descriptor: nil,
            journal: episodeJournal,
            workJournal: nil,
            allowedEpisodeIDs: [fixture.episodeID],
            remoteAvailability: .temporarilyOffline
        )
        let packageOnly = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: transportCounter,
            journal: InMemoryWorkSyncJournal(),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: binding.localWorkingCopyID,
            packageName: "whole-work-missing-journal.novelpkg",
            localBinding: { _, _, _ in missingJournal },
            remoteBinding: { _, _, _ in
                await bindingCounter.increment()
                return nil
            }
        )
        await packageOnly.store.refreshOrPrepareWorkDeviceSync()
        let lookup = try #require(packageOnly.store.currentDeviceSyncLookupIdentity)
        #expect(packageOnly.store.deviceSyncLocalRecoveryPending == false)
        #expect(packageOnly.store.deviceSyncAllowsEditing(for: lookup))
        packageOnly.store.updateDocumentTitle("同期警告中も編集")
        #expect(await packageOnly.store.saveNow())
        #expect(try await packageOnly.repository.load(from: packageOnly.store.documentURL).title == "同期警告中も編集")
        #expect(await bindingCounter.value() == 0)
        #expect(await transportCounter.callCount() == 0)

        let mismatchCounter = IOSAsyncInvocationCounter()
        let mismatchTransport = IOSCountingWorkSyncTransport(base: InMemoryWorkSyncServer())
        let mismatchedDescriptor = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: fixture.document.id,
            structureDigest: fixture.structureDigest,
            title: fixture.document.title
        )
        let mismatchedLocal = IOSDeviceSyncBindingResolution(
            binding: binding,
            descriptor: mismatchedDescriptor,
            journal: episodeJournal,
            workJournal: InMemoryWorkSyncJournal(),
            allowedEpisodeIDs: [fixture.episodeID],
            remoteAvailability: .available
        )
        let locallyDurable = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: mismatchTransport,
            journal: InMemoryWorkSyncJournal(),
            replicaID: SyncReplicaID(),
            localWorkingCopyID: binding.localWorkingCopyID,
            packageName: "whole-work-mismatched-descriptor.novelpkg",
            localBinding: { _, _, _ in mismatchedLocal },
            remoteBinding: { _, _, _ in
                await mismatchCounter.increment()
                return nil
            }
        )
        await locallyDurable.store.refreshOrPrepareWorkDeviceSync()
        let durableLookup = try #require(locallyDurable.store.currentDeviceSyncLookupIdentity)
        #expect(locallyDurable.store.deviceSyncLocalRecoveryPending == false)
        #expect(locallyDurable.store.deviceSyncAllowsEditing(for: durableLookup))
        #expect(locallyDurable.store.deviceSyncState == .blocked)
        locallyDurable.store.updateDocumentTitle("端末journalにも保存")
        #expect(await locallyDurable.store.saveNow())
        try await Task.sleep(for: .milliseconds(50))
        #expect(await mismatchCounter.value() == 0)
        #expect(await mismatchTransport.callCount() == 0)
    }

    private func makeWholeWorkStore(
        fixture: IOSDeviceSyncFixture,
        workServer: InMemoryWorkSyncServer,
        journal: any WorkSyncJournal,
        replicaID: SyncReplicaID,
        localWorkingCopyID: LocalWorkingCopyID,
        packageName: String
    ) throws -> (store: IOSDocumentStore, repository: IOSDeviceSyncRepository) {
        try makeWholeWorkStore(
            fixture: fixture,
            workTransport: workServer,
            journal: journal,
            replicaID: replicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: packageName
        )
    }

    private func makeWholeWorkStore(
        fixture: IOSDeviceSyncFixture,
        workTransport: any WorkSyncTransport,
        journal: any WorkSyncJournal,
        replicaID: SyncReplicaID,
        localWorkingCopyID: LocalWorkingCopyID,
        packageName: String,
        localBinding: (@Sendable (
            IOSPrivateDocumentID,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> IOSDeviceSyncBindingResolution?)? = nil,
        remoteBinding: (@Sendable (
            IOSPrivateDocumentID,
            UUID,
            SyncWorkStructureDigest
        ) async throws -> IOSDeviceSyncBindingResolution?)? = nil
    ) throws -> (store: IOSDocumentStore, repository: IOSDeviceSyncRepository) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-WorkSync-Tests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(packageName, isDirectory: true)
        let repository = IOSDeviceSyncRepository(initialDocument: fixture.document, at: url)
        let episodeServer = InMemoryEpisodeSyncServer()
        let episodeJournal = InMemoryEpisodeSyncJournal()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: localWorkingCopyID,
            workID: fixture.key.workID
        )
        let local = IOSDeviceSyncBindingResolution(
            binding: binding,
            descriptor: nil,
            journal: episodeJournal,
            workJournal: journal,
            allowedEpisodeIDs: Set(fixture.document.chapters.flatMap(\.episodes).map(\.id)),
            remoteAvailability: .temporarilyOffline
        )
        let remote = IOSDeviceSyncBindingResolution(
            binding: binding,
            descriptor: SyncWorkDescriptor(
                workID: fixture.key.workID,
                sourceDocumentID: fixture.document.id,
                structureDigest: fixture.structureDigest,
                title: fixture.document.title
            ),
            journal: episodeJournal,
            workJournal: journal,
            allowedEpisodeIDs: local.allowedEpisodeIDs,
            remoteAvailability: .available
        )
        let runtime = IOSDeviceSyncRuntime(
            replicaID: replicaID,
            transport: episodeServer,
            workTransport: workTransport,
            localWorkBinding: localBinding ?? { _, _, _ in local },
            binding: remoteBinding ?? { _, _, _ in remote },
            now: { Date(timeIntervalSince1970: 10000) }
        )
        let store = IOSDocumentStore(
            repository: repository,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            deviceSyncRuntime: runtime,
            libraryRoot: root
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.install(fixture.document, at: url, attachments: [])
        store.startupState = .ready
        store.saveState = .saved
        return (store, repository)
    }

    private func verifyWorkJournalFailureFencesPendingRemote(
        failAfterSuccessfulSaves: Int
    ) async throws {
        let fixture = try makeFixture(content: "本文")
        let server = InMemoryWorkSyncServer()
        let remote = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await remote.bootstrapLocalSnapshot(
            WorkSnapshot(document: fixture.document),
            at: Date(timeIntervalSince1970: 8070)
        )
        _ = try await remote.synchronize(at: Date(timeIntervalSince1970: 8071))
        let sharedBase = try #require(await server.currentHead(for: fixture.key.workID))
        let journal = IOSIndexedFailureWorkSyncJournal()
        let localWorkingCopyID = LocalWorkingCopyID()
        let localReplicaID = SyncReplicaID()
        let localBootstrap = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: localReplicaID,
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: journal
        )
        _ = try await localBootstrap.bootstrapRemoteRevision(sharedBase)
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: server,
            journal: journal,
            replicaID: localReplicaID,
            localWorkingCopyID: localWorkingCopyID,
            packageName: "whole-work-journal-fence-\(failAfterSuccessfulSaves).novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()

        var remoteDocument = fixture.document
        remoteDocument.synopsis = "iCloud側のあらすじ"
        let remoteStage = try await remote.stageLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 8072)
        )
        try await remote.confirmLocalSnapshotMaterialized(
            remoteStage.revisionID,
            packageSnapshot: remoteStage.snapshot
        )
        _ = try await remote.synchronize(at: Date(timeIntervalSince1970: 8073))
        let client = try #require(app.store.workSyncClient)
        _ = try await client.coordinator.synchronize(at: Date(timeIntervalSince1970: 8074))
        #expect(try await client.coordinator.currentState().pendingRemoteMaterialization != nil)

        await journal.fail(afterSuccessfulSaves: failAfterSuccessfulSaves)
        app.store.updateDocumentTitle("端末packageだけの題名")
        #expect(await app.store.flushDeviceSyncForBackground() == false)
        let preserved = try await app.repository.load(from: app.store.documentURL)
        #expect(preserved.title == "端末packageだけの題名")
        #expect(preserved.synopsis == fixture.document.synopsis)
        #expect(app.store.document.title == "端末packageだけの題名")
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)
        #expect(try await client.coordinator.currentState().pendingRemoteMaterialization != nil)

        #expect(await app.store.flushDeviceSyncForBackground())
        let merged = try await app.repository.load(from: app.store.documentURL)
        #expect(merged.title == "端末packageだけの題名")
        #expect(merged.synopsis == "iCloud側のあらすじ")
        #expect(try await client.coordinator.currentState().stagedLocalRevision == nil)
    }

    private func verifyWorkJournalFailureFencesConflictChoice(
        failAfterSuccessfulSaves: Int
    ) async throws {
        let fixture = try makeFixture(content: "本文")
        let server = InMemoryWorkSyncServer()
        var remoteDocument = fixture.document
        remoteDocument.title = "iCloudの競合題名"
        let remote = WorkSyncCoordinator(
            workID: fixture.key.workID,
            localWorkingCopyID: LocalWorkingCopyID(),
            replicaID: SyncReplicaID(),
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await remote.bootstrapLocalSnapshot(
            WorkSnapshot(document: remoteDocument),
            at: Date(timeIntervalSince1970: 8080)
        )
        _ = try await remote.synchronize(at: Date(timeIntervalSince1970: 8081))
        let journal = IOSIndexedFailureWorkSyncJournal()
        let app = try makeWholeWorkStore(
            fixture: fixture,
            workTransport: server,
            journal: journal,
            replicaID: SyncReplicaID(),
            localWorkingCopyID: LocalWorkingCopyID(),
            packageName: "whole-work-conflict-journal-fence-\(failAfterSuccessfulSaves).novelpkg"
        )
        await app.store.refreshOrPrepareWorkDeviceSync()
        let originalReview = try #require(app.store.workSyncConflictReview)

        await journal.fail(afterSuccessfulSaves: failAfterSuccessfulSaves)
        app.store.updateDocumentSynopsis("競合画面を開いた後の端末追記")
        await app.store.resolveWorkSyncConflict(using: .keepRemote, expectedReview: originalReview)

        var package = try await app.repository.load(from: app.store.documentURL)
        #expect(package.title == fixture.document.title)
        #expect(package.synopsis == "競合画面を開いた後の端末追記")
        #expect(app.store.document == package)
        #expect(app.store.deviceSyncLocalDurabilityState == .failed)
        #expect(app.store.workSyncConflictReview?.id == originalReview.id)

        // failureは1回だけ。再試行ではpackage-only tailをjournalへ回収して
        // reviewを更新し、古い選択をそのまま適用しない。
        await app.store.resolveWorkSyncConflict(using: .keepRemote, expectedReview: originalReview)
        package = try await app.repository.load(from: app.store.documentURL)
        let updatedReview = try #require(app.store.workSyncConflictReview)
        #expect(updatedReview.id != originalReview.id)
        #expect(updatedReview.local.snapshot.synopsis == "競合画面を開いた後の端末追記")
        #expect(package.title == fixture.document.title)
        #expect(package.synopsis == "競合画面を開いた後の端末追記")
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
    private var failingSaveTitle: String?

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
        if document.title == failingSaveTitle {
            failingSaveTitle = nil
            throw IOSDeviceSyncTestError.injectedPackageSaveFailure
        }
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

    func failNextSave(matchingTitle title: String) {
        failingSaveTitle = title
    }

    func saveCopy(_ document: NovelDocument, from _: URL, to destinationURL: URL) async throws {
        documents[destinationURL.standardizedFileURL.path] = document
    }

    func setSaveObserver(_ observer: (@Sendable (NovelDocument) async -> Void)?) {
        saveObserver = observer
    }
}

private actor IOSFailingOnceWorkSyncJournal: WorkSyncJournal {
    private var records: [SyncWorkID: WorkSyncJournalRecord] = [:]
    private var shouldFailNextSave = false

    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        records[workID]
    }

    func save(_ record: WorkSyncJournalRecord) async throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw IOSDeviceSyncTestError.workJournalFailure
        }
        records[record.workID] = record
    }

    func failNextSave() {
        shouldFailNextSave = true
    }
}

private actor IOSIndexedFailureWorkSyncJournal: WorkSyncJournal {
    private var records: [SyncWorkID: WorkSyncJournalRecord] = [:]
    private var successfulSavesBeforeFailure: Int?

    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        records[workID]
    }

    func save(_ record: WorkSyncJournalRecord) async throws {
        if let remaining = successfulSavesBeforeFailure {
            if remaining == 0 {
                successfulSavesBeforeFailure = nil
                throw IOSDeviceSyncTestError.workJournalFailure
            }
            successfulSavesBeforeFailure = remaining - 1
        }
        records[record.workID] = record
    }

    func fail(afterSuccessfulSaves count: Int) {
        successfulSavesBeforeFailure = max(0, count)
    }
}

private actor IOSPausableLoadWorkSyncJournal: WorkSyncJournal {
    private var record: WorkSyncJournalRecord
    private var shouldPauseNextLoad = false
    private var pausedLoad: CheckedContinuation<Void, Never>?

    init(record: WorkSyncJournalRecord) {
        self.record = record
    }

    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        guard record.workID == workID else { return nil }
        if shouldPauseNextLoad {
            shouldPauseNextLoad = false
            await withCheckedContinuation { continuation in
                pausedLoad = continuation
            }
        }
        return record
    }

    func save(_ record: WorkSyncJournalRecord) async throws {
        self.record = record
    }

    func pauseNextLoad() {
        shouldPauseNextLoad = true
    }

    func isLoadPaused() -> Bool {
        pausedLoad != nil
    }

    func resumeLoad() {
        let continuation = pausedLoad
        pausedLoad = nil
        continuation?.resume()
    }
}

private actor IOSAsyncInvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor IOSCountingWorkSyncTransport: WorkSyncTransport {
    private let base: any WorkSyncTransport
    private var calls = 0

    init(base: any WorkSyncTransport) {
        self.base = base
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        calls += 1
        return try await base.fetchSnapshot(for: workID)
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        calls += 1
        return try await base.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        calls += 1
        return try await base.publish(request)
    }

    func callCount() -> Int {
        calls
    }
}

private actor IOSAvailabilityControlledWorkSyncTransport: WorkSyncTransport {
    private let base: any WorkSyncTransport
    private var isOnline = true
    private var shouldPauseNextRequestThenFail = false
    private var pausedRequest: CheckedContinuation<Void, Never>?
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var requestCount = 0

    init(base: any WorkSyncTransport) {
        self.base = base
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await beginRequest()
        return try await base.fetchSnapshot(for: workID)
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        try await beginRequest()
        return try await base.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        try await beginRequest()
        return try await base.publish(request)
    }

    func setOnline(_ online: Bool) {
        isOnline = online
    }

    func pauseNextRequestThenFail() {
        shouldPauseNextRequestThenFail = true
    }

    func waitUntilRequestIsPaused() async {
        if pausedRequest != nil {
            return
        }
        await withCheckedContinuation { pauseObservers.append($0) }
    }

    func resumePausedRequest() {
        pausedRequest?.resume()
        pausedRequest = nil
    }

    func callCount() -> Int {
        requestCount
    }

    private func beginRequest() async throws {
        requestCount += 1
        if shouldPauseNextRequestThenFail {
            shouldPauseNextRequestThenFail = false
            let observers = pauseObservers
            pauseObservers.removeAll()
            await withCheckedContinuation { continuation in
                pausedRequest = continuation
                observers.forEach { $0.resume() }
            }
            throw WorkSyncTransportError.unavailable
        }
        guard isOnline else { throw WorkSyncTransportError.unavailable }
    }
}

private actor IOSDivergingWorkSyncTransport: WorkSyncTransport {
    private let base: InMemoryWorkSyncServer
    private var remainingDivergences = 0
    private var shouldPauseNextPublish = false
    private var pausedPublish: CheckedContinuation<Void, Never>?
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []

    init(base: InMemoryWorkSyncServer) {
        self.base = base
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await base.fetchSnapshot(for: workID)
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        try await base.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        if shouldPauseNextPublish {
            shouldPauseNextPublish = false
            let observers = pauseObservers
            pauseObservers.removeAll()
            await withCheckedContinuation { continuation in
                pausedPublish = continuation
                observers.forEach { $0.resume() }
            }
        }
        if remainingDivergences > 0 {
            remainingDivergences -= 1
            return try await .diverged(base.fetchSnapshot(for: request.workID))
        }
        return try await base.publish(request)
    }

    func divergeNextPublishes(_ count: Int) {
        remainingDivergences = count
    }

    func pauseNextPublish() {
        shouldPauseNextPublish = true
    }

    func waitUntilPublishIsPaused() async {
        if pausedPublish != nil {
            return
        }
        await withCheckedContinuation { pauseObservers.append($0) }
    }

    func resumePausedPublish() {
        pausedPublish?.resume()
        pausedPublish = nil
    }
}

private actor IOSWorkSyncPackageOrderProbe {
    private var isObserving = false
    private var packageWasSaved = false
    private var networkBeforePackage = false
    private var networkCalls = 0

    func beginObservation() {
        isObserving = true
        packageWasSaved = false
        networkBeforePackage = false
        networkCalls = 0
    }

    func recordPackageSave() {
        guard isObserving else { return }
        packageWasSaved = true
    }

    func recordNetworkCall() {
        guard isObserving else { return }
        networkCalls += 1
        if !packageWasSaved {
            networkBeforePackage = true
        }
    }

    func networkCallCount() -> Int {
        networkCalls
    }

    func observedNetworkBeforePackage() -> Bool {
        networkBeforePackage
    }
}

private actor IOSPackageOrderedWorkSyncTransport: WorkSyncTransport {
    private let base: any WorkSyncTransport
    private let probe: IOSWorkSyncPackageOrderProbe

    init(base: any WorkSyncTransport, probe: IOSWorkSyncPackageOrderProbe) {
        self.base = base
        self.probe = probe
    }

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        await probe.recordNetworkCall()
        return try await base.fetchSnapshot(for: workID)
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        await probe.recordNetworkCall()
        return try await base.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        await probe.recordNetworkCall()
        return try await base.publish(request)
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
    case injectedPackageSaveFailure
    case missingDocument
    case textViewNotFound
    case workJournalFailure
}
