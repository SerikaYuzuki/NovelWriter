import EditorKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
import NovelSyncCloudKit
import NovelSyncTesting
import Testing

@MainActor
@Suite("Cloud library app flow", .serialized)
struct DeviceSyncCloudLibraryAppTests {
    @Test("account未設定の新規作品はlocal-onlyで開き直せる")
    func accountRequiredNewWorkStaysLocalOnly() async throws {
        let harness = try CloudLibraryHarness(connection: .accountRequired)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(state.permitsCloudLibraryMutation)
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        #expect(!state.canPublishCurrentWorkToCloud)
        let privateURL = state.documentURL
        let workingRoot = await harness.workingRootURL()
        #expect(privateURL.deletingLastPathComponent() == workingRoot)
        await allowTasksToRun()
        #expect(await harness.publishCallCount() == 0)

        state.updateDocumentTitle("作品棚へ戻る前に確定する題名")
        let workbenchSession = state.documentSessionToken
        #expect(await state.returnToStartupLibrary(expectedSession: workbenchSession))
        #expect(state.documentSessionToken != workbenchSession)
        #expect(try await NovelpkgRepository().validatePortablePackage(at: privateURL).title
            == "作品棚へ戻る前に確定する題名")
        let context = try #require(selectionContext(state))
        let row = try #require(context.works.first)
        #expect(row.title == "作品棚へ戻る前に確定する題名")
        #expect(row.availability == .localOnly)
        #expect(!row.availability.canPublishToCloud(connection: .accountRequired))
        #expect(await state.openStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(state.documentURL == privateURL)
        #expect(await harness.publishCallCount() == 0)
    }

    @Test("明示的なiCloud保存はaccountRequiredで作ったlocal-onlyをpublishする")
    func explicitPublishUploadsAccountRequiredLocalOnlyWork() async throws {
        let harness = try CloudLibraryHarness(connection: .accountRequired)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        let workID = try #require(await harness.onlyRegisteredWorkID())
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        #expect(try #require(selectionContext(state)?.works.first).availability == .localOnly)
        #expect(await harness.publishCallCount() == 0)

        await harness.setConnection(.available)
        await state.refreshStartupLibrary()
        let refreshed = try #require(selectionContext(state))
        #expect(refreshed.connection == .available)
        let row = try #require(refreshed.works.first)
        #expect(row.availability.canPublishToCloud(connection: refreshed.connection))
        let published = await state.publishStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        )
        #expect(published)
        #expect(await harness.hiddenResumeWorkIDs().contains(workID))
        #expect(await harness.publishCallCount() >= 1)
        let availability = try #require(selectionContext(state)?.works.first).availability
        #expect(availability == .cachedRemote || availability == .localPending)
        #expect(state.cloudLibraryActionMessage == nil)
        #expect(!state.startupState.isReady)
    }

    @Test("別accountでは明示的なiCloud保存を始めない")
    func explicitPublishRejectsDifferentAccount() async throws {
        let harness = try CloudLibraryHarness(connection: .differentAccount)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let row = try #require(selectionContext(state)?.works.first)
        #expect(row.availability == .localOnly)
        #expect(!row.availability.canPublishToCloud(connection: .differentAccount))
        #expect(await !(state.publishStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        )))
        #expect(await harness.publishCallCount() == 0)
    }

    @Test("複製は新しいWorkIDのlocal copyを残しchooserに留まる")
    func duplicateLeavesChooserWithTwoLocalWorks() async throws {
        let harness = try CloudLibraryHarness(connection: .accountRequired)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        state.updateDocumentTitle("複製する題名")
        let originalID = try #require(await harness.onlyRegisteredWorkID())
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let original = try #require(selectionContext(state)?.works.first)

        #expect(await state.duplicateStartupLibraryWork(
            original.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(!state.startupState.isReady)
        let works = try #require(selectionContext(state)?.works)
        #expect(works.count == 2)
        let duplicated = try #require(works.first { $0.cloudWorkID != originalID })
        #expect(duplicated.title == "複製する題名")
        #expect(duplicated.availability == .localOnly)
        #expect(try await harness.localRecord(originalID) != nil)
        #expect(try await harness.localRecord(#require(duplicated.cloudWorkID)) != nil)
        #expect(await harness.publishCallCount() == 0)
    }

    @Test("このMacから削除はlocal copyだけを外す")
    func removeLocalCopyDeletesThisDevicePackageOnly() async throws {
        let harness = try CloudLibraryHarness(connection: .accountRequired)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        let workID = try #require(await harness.onlyRegisteredWorkID())
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let row = try #require(selectionContext(state)?.works.first)

        #expect(await state.removeLocalStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(selectionContext(state)?.works.isEmpty == true)
        #expect(try await harness.localRecord(workID) == nil)
        let artifacts = try await harness.packageArtifacts(for: workID)
        #expect(!artifacts.staging)
        #expect(!artifacts.final)
        #expect(await harness.publishCallCount() == 0)
    }

    @Test("Note catalogのnil-head remote-only作品は棚に出て開ける")
    func noteCatalogRemoteOnlyWorkAppearsAndOpens() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        let workID = SyncWorkID()
        let document = NovelDocument.newDocument(title: "別端末のiCloud作品")
        try await harness.seedNoteCatalogRemoteOnly(document: document, workID: workID)
        let state = try await makeState(harness: harness)

        await state.bootstrap()

        let row = try #require(
            selectionContext(state)?.works.first { $0.reference == .cloudWork(workID.rawValue) }
        )
        #expect(row.availability == .remoteOnly)
        #expect(row.title == document.title)
        #expect(await state.openStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(state.startupState == .ready)
        #expect(state.document.title == document.title)
    }

    @Test("別iCloudアカウントではlocal copyを開けるが自動uploadしない")
    func differentAccountKeepsLocalWorkQuarantined() async throws {
        let harness = try CloudLibraryHarness(connection: .differentAccount)
        defer { Task { await harness.remove() } }
        let remoteOnlyWorkID = SyncWorkID()
        let appPendingWorkID = SyncWorkID()
        try await harness.seedRemoteOnly(
            document: NovelDocument.newDocument(title: "別accountにだけある作品"),
            workID: remoteOnlyWorkID
        )
        try await harness.seedAppOnlyRemoteIntent(
            document: NovelDocument.newDocument(title: "旧accountのdownload途中"),
            workID: appPendingWorkID
        )
        let state = try await makeState(harness: harness)

        await state.bootstrap()

        #expect(state.permitsCloudLibraryMutation)
        #expect(selectionContext(state)?.works.isEmpty == true)
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        await allowTasksToRun()
        #expect(await harness.publishCallCount() == 0)
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let context = try #require(selectionContext(state))
        #expect(context.connection == .differentAccount)
        #expect(context.works.first?.availability == .localOnly)
        #expect(!context.works.contains { $0.reference == .cloudWork(remoteOnlyWorkID.rawValue) })
        #expect(!context.works.contains { $0.reference == .cloudWork(appPendingWorkID.rawValue) })
    }

    @Test(
        "staging readback不一致は拒否し再起動でもpackageを採用しない",
        arguments: [false, true]
    )
    func stagingReadbackMismatchIsNeverAdopted(importsExternalPackage: Bool) async throws {
        let harness = try CloudLibraryHarness(connection: .accountRequired)
        defer { Task { await harness.remove() } }
        let repository = ReadbackMismatchPortableRepository()
        let state = try await makeState(harness: harness, repository: repository)

        await state.bootstrap()
        let accepted: Bool
        if importsExternalPackage {
            let sourceURL = await harness.externalImportURL()
            try await NovelpkgRepository().save(
                NovelDocument.newDocument(title: "取り込みを拒否する作品"),
                to: sourceURL
            )
            accepted = await state.importExternalDocument(
                at: sourceURL,
                expectedSession: state.documentSessionToken
            )
        } else {
            accepted = await state.createNewDocument(expectedSession: state.documentSessionToken)
        }

        #expect(!accepted)
        let workID = try #require(await harness.lastReservedWorkID())
        #expect(try await harness.localRecord(workID) == nil)
        let rejectedArtifacts = try await harness.packageArtifacts(for: workID)
        #expect(!rejectedArtifacts.staging)
        #expect(!rejectedArtifacts.final)

        let restarted = try await makeState(harness: harness, repository: repository)
        await restarted.bootstrap()

        #expect(selectionContext(restarted)?.works.isEmpty == true)
        #expect(!restarted.startupState.isReady)
        let restartedArtifacts = try await harness.packageArtifacts(for: workID)
        #expect(!restartedArtifacts.staging)
        #expect(!restartedArtifacts.final)
    }

    @Test("staging保存後attest前のkillでも同一IDの別内容を採用しない")
    func killedPreAttestationStagingCannotChangeReservedSnapshot() async throws {
        let harness = try CloudLibraryHarness(connection: .accountRequired)
        defer { Task { await harness.remove() } }
        let requested = NovelDocument.newDocument(title: "予約した作品")
        var injected = requested
        injected.title = "同じIDだが採用してはいけない内容"
        let workID = SyncWorkID()
        try await harness.seedKilledBeforeStagingAttestation(
            requested: requested,
            staged: injected,
            workID: workID
        )
        let state = try await makeState(harness: harness)

        await state.bootstrap()

        #expect(!state.startupState.isReady)
        let row = try #require(selectionContext(state)?.works.first)
        #expect(row.reference == .cloudWork(workID.rawValue))
        #expect(row.title == "予約した作品")
        #expect(row.availability == .unavailable)
        let record = try #require(await harness.localRecord(workID))
        #expect(record.state == .reservedForPublish)
        #expect(record.package?.titleProjection == "予約した作品")
        let artifacts = try await harness.packageArtifacts(for: workID)
        #expect(artifacts.staging)
        #expect(!artifacts.final)
    }

    @Test("temporary offline作成はactiveのままsignal相当の再送で同じWorkIDを公開する")
    func offlineScopedNewWorkPublishesWithoutReturningToShelf() async throws {
        let harness = try CloudLibraryHarness(connection: .offline)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        let activeSession = state.documentSessionToken
        let activeURL = state.documentURL
        await waitUntil { await harness.publishCallCount() == 1 }
        let workID = try #require(await harness.onlyRegisteredWorkID())
        #expect(await harness.hasAuthority(workID))

        await harness.setConnection(.available)
        await state.retryAccountScopedPendingPublicationsInBackground()

        #expect(await harness.publishCallCount() == 2)
        #expect(await harness.remoteHeadWorkIDs() == [workID])
        #expect(state.startupState.isReady)
        #expect(state.documentSessionToken == activeSession)
        #expect(state.documentURL == activeURL)
    }

    @Test("active中のbackground再送は他作品だけhidden coordinatorで再開する")
    func backgroundRetryResumesInactivePendingWorkHidden() async throws {
        let harness = try CloudLibraryHarness(connection: .offline)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        await waitUntil { await harness.publishCallCount() == 1 }
        let activeWorkID = try #require(await harness.onlyRegisteredWorkID())
        let inactiveWorkID = SyncWorkID()
        try await harness.seedPublishPending(
            document: NovelDocument.newDocument(title: "裏で公開を再開する作品"),
            workID: inactiveWorkID
        )
        await harness.setConnection(.available)

        await state.retryAccountScopedPendingPublicationsInBackground()

        #expect(await harness.activeDocumentPublishWorkIDs() == [activeWorkID, activeWorkID])
        #expect(await harness.hiddenResumeWorkIDs() == [inactiveWorkID])
    }

    @Test("統合レビュー中でも検証済みのローカル作品を作品棚から開ける")
    func reviewRequiredLocalPackageOpensFromShelf() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        let workID = SyncWorkID()
        let document = NovelDocument.newDocument(title: "統合レビュー中の作品")
        try await harness.seedPublishPending(document: document, workID: workID)
        await harness.markWorkNeedsReview(workID)
        let state = try await makeState(harness: harness)

        await state.bootstrap()

        let row = try #require(selectionContext(state)?.works.first)
        #expect(row.availability == .needsReview)
        #expect(await state.openStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(state.startupState == .ready)
        #expect(state.document.title == document.title)
    }

    @Test("hidden再送中も作品切替はremote待ちせずlocal境界で完了する")
    func backgroundRetryDoesNotBlockDocumentActivation() async throws {
        let harness = try CloudLibraryHarness(connection: .offline)
        defer { Task { await harness.remove() } }
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        await waitUntil { await harness.publishCallCount() == 1 }
        let inactiveWorkID = SyncWorkID()
        try await harness.seedPublishPending(
            document: NovelDocument.newDocument(title: "切替と直列化する作品"),
            workID: inactiveWorkID
        )
        await harness.setConnection(.available)
        await harness.pauseNextHiddenResume()

        let retry = Task { await state.retryAccountScopedPendingPublicationsInBackground() }
        await waitUntil { await harness.isHiddenResumePaused() }
        #expect(await harness.hiddenResumeWorkIDs() == [inactiveWorkID])
        let activeSession = state.documentSessionToken
        let returnToLibrary = Task {
            await state.returnToStartupLibrary(expectedSession: activeSession)
        }
        await allowTasksToRun()
        #expect(!state.startupState.isReady)

        await harness.resumePausedHiddenResume()
        await retry.value
        #expect(await returnToLibrary.value)
        #expect(!state.startupState.isReady)
    }

    @Test("bind完了後にcatalogが空でも再起動時に一度だけ再送して同期済みにする")
    func restartedBoundPublicationMissingFromCatalogResumesExactlyOnce() async throws {
        let harness = try CloudLibraryHarness(connection: .offline)
        defer { Task { await harness.remove() } }
        let initial = try await makeState(harness: harness)

        await initial.bootstrap()
        #expect(await initial.createNewDocument(expectedSession: initial.documentSessionToken))
        await waitUntil { await harness.publishCallCount() == 1 }
        let workID = try #require(await harness.onlyRegisteredWorkID())
        await harness.hideRemoteCatalog()
        await harness.setConnection(.available)

        let restarted = try await makeState(harness: harness)
        await restarted.bootstrap()

        #expect(await harness.publishCallCount() == 2)
        #expect(try await harness.localRecord(workID)?.state == .synced)
        #expect(selectionContext(restarted)?.works.first?.availability == .cachedRemote)

        await restarted.refreshStartupLibrary()
        #expect(await harness.publishCallCount() == 2)
    }

    @Test("pending creationの同じ失敗は再送signalを自己増殖させない")
    func repeatedPendingCreationFailureDoesNotRepublishRecursively() async throws {
        let fixture = try ProductionRuntimeSignalFixture()
        defer { fixture.remove() }
        let locator = try AppleLocalDocumentLocator.cloudLibrary(workID: SyncWorkID())
        let collector = Task {
            var count = 0
            for await _ in fixture.signals {
                count += 1
            }
            return count
        }

        #expect(await fixture.runtime.recordCreationFailureLocalBinding(
            locator,
            status: .unbound
        ) == false)
        #expect(await fixture.runtime.recordCreationFailureLocalBinding(locator, status: .bound))
        #expect(await fixture.runtime.recordCreationFailureLocalBinding(
            locator,
            status: .bound
        ) == false)
        #expect(await fixture.runtime.recordCreationFailureLocalBinding(
            locator,
            status: .boundAndBlocked(.temporarilyUnavailable)
        ) == false)
        #expect(await fixture.runtime.recordKnownLocalBinding(locator) == false)
        fixture.finishSignals()

        #expect(await collector.value == 1)
    }

    @Test("production runtimeは再起動後の2件outboxを一度だけ送信する")
    func productionRuntimeResumesDurableWorkOutboxExactlyOnce() async throws {
        let fixture = try ProductionRuntimeSignalFixture()
        defer { fixture.remove() }
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let first = try WorkSnapshot(document: NovelDocument.newDocument(title: "最初の版"))
        var updatedDocument = try first.materializedDocument()
        updatedDocument.title = "再起動前の版"
        let updated = try WorkSnapshot(document: updatedDocument)
        let branchID = SyncBranchID()
        let sessionID = SyncEditSessionID()
        let rootRevision = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: branchID,
            authorReplicaID: fixture.replicaID,
            authorSessionID: sessionID,
            snapshot: first,
            clientCreatedAt: Date(timeIntervalSince1970: 100)
        )
        let updatedRevision = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [rootRevision.revisionID],
            branchID: branchID,
            authorReplicaID: fixture.replicaID,
            authorSessionID: sessionID,
            snapshot: updated,
            clientCreatedAt: Date(timeIntervalSince1970: 101)
        )
        try await journal.save(
            WorkSyncJournalRecord(
                workID: workID,
                localWorkingCopyID: binding.localWorkingCopyID,
                replicaID: fixture.replicaID,
                branchID: branchID,
                lastKnownRemoteHead: nil,
                localHead: updatedRevision,
                outbox: [rootRevision, updatedRevision]
            )
        )
        let seededRecord = try #require(await journal.storedRecord(for: workID))
        #expect(seededRecord.outbox.count == 2)

        await transport.pauseNextPublish()
        let firstRetry = Task {
            try await fixture.runtime.resumeInitialWorkPublication(
                binding: binding,
                journal: journal,
                transport: transport,
                initialSnapshot: updated,
                at: Date(timeIntervalSince1970: 102)
            )
        }
        #expect(await transport.waitUntilPublishIsPaused())
        let coalescedRetry = Task {
            try await fixture.runtime.resumeInitialWorkPublication(
                binding: binding,
                journal: journal,
                transport: transport,
                initialSnapshot: updated,
                at: Date(timeIntervalSince1970: 102)
            )
        }
        await allowTasksToRun()
        #expect(await transport.publishCallCount() == 1)
        await transport.resumePausedPublish()
        try await firstRetry.value
        try await coalescedRetry.value

        #expect(await transport.publishCallCount() == 1)
        #expect(await transport.currentHead(for: workID)?.snapshot == updated)
        let publishedRecord = try #require(await journal.storedRecord(for: workID))
        #expect(publishedRecord.outbox.isEmpty)

        try await fixture.runtime.resumeInitialWorkPublication(
            binding: binding,
            journal: journal,
            transport: transport,
            initialSnapshot: updated,
            at: Date(timeIntervalSince1970: 103)
        )
        #expect(await transport.publishCallCount() == 1)
    }

    @Test("production runtimeはjournal作成前のkill窓をexact snapshotから一度だけ公開する")
    func productionRuntimeBootstrapsMissingWorkJournalExactlyOnce() async throws {
        let fixture = try ProductionRuntimeSignalFixture()
        defer { fixture.remove() }
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let snapshot = try WorkSnapshot(
            document: NovelDocument.newDocument(title: "journal前に確定済みの作品")
        )

        try await fixture.runtime.resumeInitialWorkPublication(
            binding: binding,
            journal: journal,
            transport: transport,
            initialSnapshot: snapshot,
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(await transport.publishCallCount() == 1)
        #expect(await transport.currentHead(for: workID)?.snapshot == snapshot)
        let record = try #require(await journal.storedRecord(for: workID))
        #expect(record.outbox.isEmpty)
        #expect(record.reconciliationStatus == .synchronized)

        try await fixture.runtime.resumeInitialWorkPublication(
            binding: binding,
            journal: journal,
            transport: transport,
            initialSnapshot: snapshot,
            at: Date(timeIntervalSince1970: 201)
        )
        #expect(await transport.publishCallCount() == 1)
    }

    @Test("production runtimeはofflineになった初回outboxを接続回復後に再送する")
    func productionRuntimeRetriesOfflineInitialJournal() async throws {
        let fixture = try ProductionRuntimeSignalFixture()
        defer { fixture.remove() }
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let snapshot = try WorkSnapshot(
            document: NovelDocument.newDocument(title: "接続後に再送する作品")
        )
        await transport.failNextPublishAsUnavailable()

        try await fixture.runtime.resumeInitialWorkPublication(
            binding: binding,
            journal: journal,
            transport: transport,
            initialSnapshot: snapshot,
            at: Date(timeIntervalSince1970: 250)
        )
        let offline = try #require(await journal.storedRecord(for: workID))
        #expect(offline.reconciliationStatus == .offline)
        #expect(offline.outbox.count == 1)

        try await fixture.runtime.resumeInitialWorkPublication(
            binding: binding,
            journal: journal,
            transport: transport,
            initialSnapshot: snapshot,
            at: Date(timeIntervalSince1970: 251)
        )
        let synchronized = try #require(await journal.storedRecord(for: workID))
        #expect(synchronized.reconciliationStatus == .synchronized)
        #expect(synchronized.outbox.isEmpty)
        #expect(await transport.publishCallCount() == 2)
    }

    @Test("production runtimeはpackageと異なるjournalをhidden resumeしない")
    func productionRuntimeRefusesMismatchedInitialJournal() async throws {
        let fixture = try ProductionRuntimeSignalFixture()
        defer { fixture.remove() }
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let seed = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: binding.localWorkingCopyID,
            replicaID: fixture.replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        let storedSnapshot = try WorkSnapshot(
            document: NovelDocument.newDocument(title: "journal側の作品")
        )
        _ = try await seed.bootstrapLocalSnapshot(
            storedSnapshot,
            at: Date(timeIntervalSince1970: 300)
        )
        var packageDocument = try storedSnapshot.materializedDocument()
        packageDocument.title = "package側だけ進んだ作品"
        let packageSnapshot = try WorkSnapshot(document: packageDocument)
        let before = await journal.storedRecord(for: workID)

        await #expect(throws: WorkSyncCoordinatorError.packageSnapshotMismatch) {
            try await fixture.runtime.resumeInitialWorkPublication(
                binding: binding,
                journal: journal,
                transport: transport,
                initialSnapshot: packageSnapshot,
                at: Date(timeIntervalSince1970: 301)
            )
        }

        #expect(await transport.publishCallCount() == 0)
        let after = await journal.storedRecord(for: workID)
        #expect(after == before)
    }

    @Test("production runtimeはremote既知のjournalをactive preflightから奪わない")
    func productionRuntimeRefusesRemoteKnownJournal() async throws {
        let fixture = try ProductionRuntimeSignalFixture()
        defer { fixture.remove() }
        let workID = SyncWorkID()
        let binding = SyncWorkingCopyBinding(
            localWorkingCopyID: LocalWorkingCopyID(),
            workID: workID
        )
        let journal = InMemoryWorkSyncJournal()
        let transport = CountingWorkSyncTransport()
        let seed = WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: binding.localWorkingCopyID,
            replicaID: fixture.replicaID,
            sessionID: SyncEditSessionID(),
            transport: transport,
            journal: journal
        )
        let first = try WorkSnapshot(document: NovelDocument.newDocument(title: "同期済み"))
        _ = try await seed.bootstrapLocalSnapshot(first, at: Date(timeIntervalSince1970: 400))
        _ = try await seed.synchronize(at: Date(timeIntervalSince1970: 401))
        var updatedDocument = try first.materializedDocument()
        updatedDocument.title = "同期後のlocal変更"
        let updated = try WorkSnapshot(document: updatedDocument)
        let staged = try await seed.stageLocalSnapshot(updated, at: Date(timeIntervalSince1970: 402))
        try await seed.confirmLocalSnapshotMaterialized(
            staged.revisionID,
            packageSnapshot: updated
        )
        let before = await journal.storedRecord(for: workID)

        await #expect(throws: DeviceSyncInitialWorkPublicationError.requiresActiveDocumentPreflight) {
            try await fixture.runtime.resumeInitialWorkPublication(
                binding: binding,
                journal: journal,
                transport: transport,
                initialSnapshot: updated,
                at: Date(timeIntervalSince1970: 403)
            )
        }

        #expect(await transport.publishCallCount() == 1)
        let after = await journal.storedRecord(for: workID)
        #expect(after == before)
    }

    @Test("remote catalog失敗でもlocal-only新規を端末へ保存できる")
    func remoteCatalogFailureDoesNotBlockLocalCreation() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        await harness.setRemoteLoadFailure(true)
        let state = try await makeState(harness: harness)

        await state.bootstrap()

        #expect(state.permitsCloudLibraryMutation)
        #expect(selectionContext(state)?.connection == .unavailable(
            message: "iCloudの作品を更新できませんでした。"
        ))
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        await allowTasksToRun()
        #expect(await harness.publishCallCount() == 0)
        let workID = try #require(await harness.onlyRegisteredWorkID())
        let record = try await harness.localRecord(workID)
        #expect(record?.state == .publishPending)
        #expect(state.canPublishCurrentWorkToCloud)
        #expect(state.lastStartupLibraryConnection.allowsExplicitCloudPublish)
    }

    @Test("catalog失敗中でもWorkbenchから明示iCloud保存できる")
    func catalogFailureAllowsWorkbenchExplicitPublish() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        await harness.setRemoteLoadFailure(true)
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        #expect(state.canPublishCurrentWorkToCloud)
        #expect(await state.publishCurrentLibraryWork(
            expectedSession: state.documentSessionToken
        ))
        #expect(await harness.publishCallCount() >= 1)
        #expect(state.cloudLibraryActionMessage == nil)
        #expect(state.isCurrentWorkBoundToCloud)
        #expect(!state.canPublishCurrentWorkToCloud)
    }

    @Test("catalog失敗中のlocal-only行は作品棚から明示保存できる")
    func catalogFailureShowsChooserPublishControl() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        await harness.setRemoteLoadFailure(true)
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let context = try #require(selectionContext(state))
        #expect(context.connection.allowsExplicitCloudPublish)
        let row = try #require(context.works.first)
        #expect(row.availability == .localOnly)
        #expect(row.availability.canPublishToCloud(connection: context.connection))
        #expect(await state.publishStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(await harness.publishCallCount() >= 1)
        #expect(!state.isStartupLibraryOperationInProgress)
    }

    @Test("作品棚の明示保存後、catalog待ちでも再操作できる")
    func chooserPublishClearsInProgressBeforeCatalogRefresh() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        await harness.setRemoteLoadFailure(true)
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let row = try #require(selectionContext(state)?.works.first)

        await harness.setRemoteLoadFailure(false)
        await harness.pauseNextRemoteLoad()
        let publish = Task { @MainActor in
            await state.publishStartupLibraryWork(
                row.reference,
                expectedSession: state.documentSessionToken
            )
        }
        await waitUntil { await harness.remoteLoadIsPaused() }
        #expect(!state.isStartupLibraryOperationInProgress)
        await harness.resumePausedRemoteLoad()
        #expect(await publish.value)
    }

    @Test("作品棚の明示保存失敗後も再試行できる")
    func chooserPublishFailureClearsInProgress() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        await harness.setRemoteLoadFailure(true)
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))
        #expect(await state.returnToStartupLibrary(expectedSession: state.documentSessionToken))
        let row = try #require(selectionContext(state)?.works.first)

        await harness.failNextPublish()
        #expect(await state.publishStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ) == false)
        #expect(!state.isStartupLibraryOperationInProgress)
        #expect(state.cloudLibraryActionMessage != nil)
    }

    @Test("local-first起動はremote catalog停止中でも作品棚を返す")
    func localFirstBootstrapDoesNotWaitForRemoteCatalog() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        await harness.pauseNextRemoteLoad()
        let state = try await makeState(harness: harness)

        let bootstrap = Task { @MainActor in
            await state.bootstrap(localFirst: true)
        }
        await waitUntil { await harness.remoteLoadIsPaused() }

        #expect(!state.startupState.isReady)
        let context = try #require(selectionContext(state))
        #expect(!context.isLoading)
        #expect(state.permitsCloudLibraryMutation)

        await harness.resumePausedRemoteLoad()
        await bootstrap.value
    }

    @Test("Domainだけに残ったdownload intentは作品名を漏らさずoffline再開できる")
    func domainOnlyPendingOpenReturnsAsGenericOfflineRow() async throws {
        let harness = try CloudLibraryHarness(connection: .offline)
        defer { Task { await harness.remove() } }
        let remoteDocument = NovelDocument.newDocument(title: "旧accountへ漏らしてはいけない題名")
        let workID = SyncWorkID()
        try await harness.seedResumableRemote(document: remoteDocument, workID: workID)
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        let context = try #require(selectionContext(state))
        let row = try #require(context.works.first)
        #expect(row.reference == .cloudWork(workID.rawValue))
        #expect(row.title == "このMacへの保存を再開する作品")
        #expect(row.availability == .remotePending)

        #expect(await state.openStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(state.document == remoteDocument)
        let workingRoot = await harness.workingRootURL()
        #expect(state.documentURL.deletingLastPathComponent() == workingRoot)
    }

    @Test("remote bind後のregistry mark killはoffline再起動でもexact packageを復旧する")
    func completedRemoteOpenPromotesOfflineWithoutCatalog() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        let document = NovelDocument.newDocument(title: "復旧する作品")
        let workID = SyncWorkID()
        try await harness.seedCompletedRemoteBeforeRegistryMark(
            document: document,
            workID: workID
        )
        await harness.setConnection(.offline)
        await harness.hideRemoteCatalog()
        let state = try await makeState(harness: harness)

        await state.bootstrap()

        let row = try #require(selectionContext(state)?.works.first)
        #expect(row.reference == .cloudWork(workID.rawValue))
        #expect(row.availability == .cachedRemote)
        #expect(selectionContext(state)?.connection == .offline)
        #expect(await harness.remoteHeadWorkIDs().isEmpty)
        let record = try await harness.localRecord(workID)
        #expect(record?.state == .synced)
    }

    @Test("接続中catalogから消えた同期済み作品はcheckmarkとopenを止める")
    func missingAvailableCatalogEntryDoesNotClaimSynced() async throws {
        let harness = try CloudLibraryHarness(connection: .available)
        defer { Task { await harness.remove() } }
        let document = NovelDocument.newDocument(title: "catalogから消えた作品")
        let workID = SyncWorkID()
        try await harness.seedCompletedRemoteBeforeRegistryMark(
            document: document,
            workID: workID
        )
        let state = try await makeState(harness: harness)

        await state.bootstrap()
        #expect(selectionContext(state)?.works.first?.availability == .cachedRemote)

        await harness.hideRemoteCatalog()
        await state.refreshStartupLibrary()

        let context = try #require(selectionContext(state))
        #expect(context.connection == .available)
        let row = try #require(context.works.first)
        #expect(row.reference == .cloudWork(workID.rawValue))
        #expect(row.availability == .cloudUnavailable)
        let opened = await state.openStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        )
        #expect(!opened)
        #expect(!state.startupState.isReady)
    }

    private func makeState(
        harness: CloudLibraryHarness,
        repository: any DocumentRepository = NovelpkgRepository()
    ) async throws -> AppState {
        let runtime = await DeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            binding: { _, _ in nil },
            library: harness.runtime()
        )
        return AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: isolatedDefaults(),
                fileManager: .default,
                editorCommandSession: EditorCommandSession(),
                deviceSyncRuntime: runtime
            )
        )
    }

    private func selectionContext(_ state: AppState) -> StartupDocumentSelectionContext? {
        guard case let .documentSelection(context) = state.startupState else { return nil }
        return context
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "FUMINIWA.CloudLibraryAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func allowTasksToRun() async {
        for _ in 0 ..< 40 {
            await Task.yield()
        }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0 ..< 500 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct ProductionRuntimeSignalFixture {
    let baseURL: URL
    let replicaID: SyncReplicaID
    let signals: AsyncStream<Void>
    let runtime: DeviceSyncProductionRuntimeBox
    private let signalContinuation: AsyncStream<Void>.Continuation

    init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CloudLibraryHarnessError.fixtureSetup(
                stage: "application-support",
                underlying: "missing user application support directory"
            )
        }
        baseURL = applicationSupport
            .appendingPathComponent("FUMINIWATests", isDirectory: true)
            .appendingPathComponent("fuminiwa-runtime-signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let workingRoot = try DeviceSyncPrivateWorkingCopyRoot.prepare(
            baseURL.appendingPathComponent("SyncWorkingCopies-v2", isDirectory: true),
            fileManager: .default
        )
        let localStore = try DeviceSyncLocalLibraryStore(
            registryRootURL: baseURL.appendingPathComponent("registry", isDirectory: true),
            trustedAncestorURL: baseURL,
            workingCopyRoot: workingRoot
        )
        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
        signals = streamPair.stream
        signalContinuation = streamPair.continuation
        let localBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(
            rootURL: baseURL.appendingPathComponent("metadata", isDirectory: true)
        )
        replicaID = localBootstrap.replicaID
        runtime = DeviceSyncProductionRuntimeBox(
            localBootstrap: localBootstrap,
            workingCopyRoot: workingRoot,
            localLibraryStore: localStore,
            signalContinuation: streamPair.continuation
        )
    }

    func finishSignals() {
        signalContinuation.finish()
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

private actor CountingWorkSyncTransport: WorkSyncTransport {
    private let server = InMemoryWorkSyncServer()
    private var publishCalls = 0
    private var shouldFailNextPublishAsUnavailable = false

    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await server.fetchSnapshot(for: workID)
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        try await server.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        publishCalls += 1
        if shouldFailNextPublishAsUnavailable {
            shouldFailNextPublishAsUnavailable = false
            throw WorkSyncTransportError.unavailable
        }
        return try await server.publish(request)
    }

    func publishCallCount() -> Int {
        publishCalls
    }

    func failNextPublishAsUnavailable() {
        shouldFailNextPublishAsUnavailable = true
    }

    func pauseNextPublish() async {
        await server.pauseNextPublish()
    }

    func waitUntilPublishIsPaused() async -> Bool {
        await server.waitUntilPublishIsPaused()
    }

    func resumePausedPublish() async {
        await server.resumePausedPublish()
    }

    func currentHead(for workID: SyncWorkID) async -> WorkRevision? {
        await server.currentHead(for: workID)
    }
}

private enum CloudLibraryHarnessError: Error {
    case unavailable
    case missingPreparedWork
    case fixtureSetup(stage: String, underlying: String)
}

private actor CloudLibraryHarness {
    private let baseURL: URL
    private let root: DeviceSyncPrivateWorkingCopyRoot
    private let store: DeviceSyncLocalLibraryStore
    private var connection: DeviceSyncLibraryConnection
    private var remoteEntries: [DeviceSyncRemoteLibraryEntry] = []
    private var resumable: [SyncWorkID: (SyncWorkLibraryEntry, NovelDocument, WorkSnapshot)] = [:]
    private var completed: Set<SyncWorkID> = []
    private var authorities: Set<SyncWorkID> = []
    private var remoteLoadFails = false
    private var shouldFailNextPublish = false
    private var shouldPauseNextRemoteLoad = false
    private var remoteLoadPaused = false
    private var resumeRemoteLoadRequested = false
    private var publishCalls: [SyncWorkID] = []
    private var activeDocumentPublishCalls: [SyncWorkID] = []
    private var hiddenResumeCalls: [SyncWorkID] = []
    private var reviewRequiredWorkIDs: Set<SyncWorkID> = []
    private var shouldPauseNextHiddenResume = false
    private var hiddenResumePaused = false
    private var mostRecentlyReservedWorkID: SyncWorkID?

    init(connection: DeviceSyncLibraryConnection) throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CloudLibraryHarnessError.fixtureSetup(
                stage: "application-support",
                underlying: "missing user application support directory"
            )
        }
        let base = applicationSupport
            .appendingPathComponent("FUMINIWATests", isDirectory: true)
            .appendingPathComponent("fuminiwa-cloud-app-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw CloudLibraryHarnessError.fixtureSetup(
                stage: "base",
                underlying: String(describing: error)
            )
        }
        let workingURL = base.appendingPathComponent("SyncWorkingCopies-v2", isDirectory: true)
        let root: DeviceSyncPrivateWorkingCopyRoot
        do {
            root = try DeviceSyncPrivateWorkingCopyRoot.prepare(workingURL, fileManager: .default)
        } catch {
            throw CloudLibraryHarnessError.fixtureSetup(
                stage: "working-copy-root",
                underlying: String(describing: error)
            )
        }
        do {
            store = try DeviceSyncLocalLibraryStore(
                registryRootURL: base.appendingPathComponent("registry", isDirectory: true),
                trustedAncestorURL: base,
                workingCopyRoot: root
            )
        } catch {
            throw CloudLibraryHarnessError.fixtureSetup(
                stage: "registry-root",
                underlying: String(describing: error)
            )
        }
        baseURL = base
        self.root = root
        self.connection = connection
    }

    func runtime() -> DeviceSyncLibraryRuntime {
        let store = store
        return DeviceSyncLibraryRuntime(
            loadLocalInventory: { try await store.inventory() },
            loadRemoteLibrary: { try await self.remoteSnapshot() },
            packageURL: { try await store.packageURL(for: $0) },
            workIDForPackageURL: { try await store.workID(for: $0) },
            stagingPackageURL: { try await store.stagingPackageURL(for: $0) },
            validateStagingPackage: { try await store.validateStagingPackage(at: $0, for: $1) },
            installStagingPackage: { try await store.installStagingPackage($0, for: $1) },
            discardStagingPackage: { try await store.discardStagingPackage($0, for: $1) },
            validateInstalledPackage: { try await store.validateInstalledPackage(for: $0) },
            reserveForPublish: {
                await self.noteReserved($0)
                try await store.reserveForPublish(workID: $0, expectedPackage: $1)
            },
            abortPublishReservation: { try await store.abortPublishReservation(workID: $0) },
            confirmPublishPackage: { try await store.confirmPublishPackage(workID: $0, package: $1) },
            attestPublishStaging: { try await store.attestPublishStaging(workID: $0, package: $1) },
            beginRemoteOpen: { try await store.beginRemoteOpen($0) },
            attestRemotePackage: {
                try await store.attestRemotePackage(workID: $0, package: $1, expectedRemote: $2)
            },
            prepareRemoteOpen: { try await self.preparedWork($0.workID, expected: $0) },
            resumeRemoteOpen: { try await self.preparedWork($0, expected: nil) },
            canResumeRemoteOpenOffline: { await self.canResume($0) },
            offlineResumableRemoteOpenWorkIDs: { await self.resumableWorkIDs() },
            hasCompletedRemoteOpenLocally: { await self.hasCompleted($0.workID) },
            localWorkNeedsReview: { workID, _ in
                await self.reviewRequiredWorkIDs.contains(workID)
            },
            markSynced: { try await store.markSynced(workID: $0, acknowledgedRemote: $1) },
            markNeedsReview: { try await store.markNeedsReview(workID: $0) },
            quarantineInstalledPackage: {
                try await store.quarantineInstalledPackage(workID: $0, package: $1)
            },
            recordPackageMutation: {
                try await store.recordPackageMutation(workID: $0, package: $1)
            },
            hasLocalPublishAuthority: { workID, _ in
                await self.authorities.contains(workID)
            },
            publishNewWork: { workID, document, _ in
                try await self.publishFromActiveDocument(workID, document: document)
            },
            resumeInitialWorkPublication: { workID, document, _ in
                try await self.resumeInitialPublication(workID, document: document)
            },
            removeLocalWork: { try await store.removeLocalWork(workID: $0) }
        )
    }

    func seedResumableRemote(document: NovelDocument, workID: SyncWorkID) throws {
        let revision = try makeRevision(document: document, workID: workID)
        resumable[workID] = try (SyncWorkLibraryEntry(head: revision), document, revision.snapshot)
    }

    func seedRemoteOnly(document: NovelDocument, workID: SyncWorkID) throws {
        let revision = try makeRevision(document: document, workID: workID)
        remoteEntries = try [
            DeviceSyncRemoteLibraryEntry(
                work: SyncWorkLibraryEntry(head: revision),
                availability: .remoteOnly
            )
        ]
    }

    func seedNoteCatalogRemoteOnly(document: NovelDocument, workID: SyncWorkID) throws {
        let snapshot = try WorkSnapshot(document: document)
        guard let workRecord = try NoteSyncProjection.records(workID: workID, snapshot: snapshot)
            .first(where: { $0.key.kind == .work }) else {
            throw CloudLibraryHarnessError.missingPreparedWork
        }
        let entry = try SyncWorkLibraryEntry(noteWork: workRecord)
        remoteEntries = [
            DeviceSyncRemoteLibraryEntry(work: entry, availability: .remoteOnly)
        ]
        resumable[workID] = (entry, document, snapshot)
    }

    func seedAppOnlyRemoteIntent(document: NovelDocument, workID: SyncWorkID) async throws {
        let revision = try makeRevision(document: document, workID: workID)
        try await store.beginRemoteOpen(SyncWorkLibraryEntry(head: revision))
    }

    func seedPublishPending(document: NovelDocument, workID: SyncWorkID) async throws {
        let attestation = try DeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await store.reserveForPublish(workID: workID, expectedPackage: attestation)
        let staging = try await store.stagingPackageURL(for: workID)
        try await NovelpkgRepository().save(document, to: staging)
        try await store.attestPublishStaging(workID: workID, package: attestation)
        _ = try await store.installStagingPackage(staging, for: workID)
        try await store.confirmPublishPackage(workID: workID, package: attestation)
        authorities.insert(workID)
    }

    func markWorkNeedsReview(_ workID: SyncWorkID) {
        reviewRequiredWorkIDs.insert(workID)
    }

    func seedKilledBeforeStagingAttestation(
        requested: NovelDocument,
        staged: NovelDocument,
        workID: SyncWorkID
    ) async throws {
        let expected = try DeviceSyncLocalPackageAttestation(
            document: requested,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await store.reserveForPublish(workID: workID, expectedPackage: expected)
        let staging = try await store.stagingPackageURL(for: workID)
        try await NovelpkgRepository().save(staged, to: staging)
    }

    func seedCompletedRemoteBeforeRegistryMark(
        document: NovelDocument,
        workID: SyncWorkID
    ) async throws {
        let revision = try makeRevision(document: document, workID: workID)
        let entry = try SyncWorkLibraryEntry(head: revision)
        try await store.beginRemoteOpen(entry)
        let staging = try await store.stagingPackageURL(for: workID)
        try await NovelpkgRepository().save(document, to: staging)
        _ = try await store.installStagingPackage(staging, for: workID)
        let attestation = try DeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await store.attestRemotePackage(
            workID: workID,
            package: attestation,
            expectedRemote: entry
        )
        completed.insert(workID)
        authorities.insert(workID)
        remoteEntries = [DeviceSyncRemoteLibraryEntry(work: entry, availability: .locallyBound)]
    }

    func setConnection(_ value: DeviceSyncLibraryConnection) {
        connection = value
    }

    func setRemoteLoadFailure(_ value: Bool) {
        remoteLoadFails = value
    }

    func failNextPublish() {
        shouldFailNextPublish = true
    }

    func pauseNextRemoteLoad() {
        shouldPauseNextRemoteLoad = true
        resumeRemoteLoadRequested = false
    }

    func remoteLoadIsPaused() -> Bool {
        remoteLoadPaused
    }

    func resumePausedRemoteLoad() {
        resumeRemoteLoadRequested = true
    }

    func hideRemoteCatalog() {
        remoteEntries = []
    }

    func publishCallCount() -> Int {
        publishCalls.count
    }

    func activeDocumentPublishWorkIDs() -> [SyncWorkID] {
        activeDocumentPublishCalls
    }

    func hiddenResumeWorkIDs() -> [SyncWorkID] {
        hiddenResumeCalls
    }

    func pauseNextHiddenResume() {
        shouldPauseNextHiddenResume = true
    }

    func isHiddenResumePaused() -> Bool {
        hiddenResumePaused
    }

    func resumePausedHiddenResume() {
        hiddenResumePaused = false
    }

    func hasAuthority(_ workID: SyncWorkID) -> Bool {
        authorities.contains(workID)
    }

    func hasCompleted(_ workID: SyncWorkID) -> Bool {
        completed.contains(workID)
    }

    func canResume(_ workID: SyncWorkID) -> Bool {
        resumable[workID] != nil
    }

    func resumableWorkIDs() -> [SyncWorkID] {
        resumable.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    func workingRootURL() -> URL {
        root.url
    }

    func externalImportURL() -> URL {
        baseURL.appendingPathComponent("external-import.novelpkg", isDirectory: true)
    }

    func packageArtifacts(for workID: SyncWorkID) async throws -> (staging: Bool, final: Bool) {
        let stagingURL = try await store.stagingPackageURL(for: workID)
        let finalURL = try await store.packageURL(for: workID)
        return (
            FileManager.default.fileExists(atPath: stagingURL.path),
            FileManager.default.fileExists(atPath: finalURL.path)
        )
    }

    func localRecord(_ workID: SyncWorkID) async throws -> DeviceSyncLocalLibraryRecord? {
        try await store.record(for: workID)
    }

    func onlyRegisteredWorkID() async throws -> SyncWorkID? {
        let records = try await store.inventory().records
        return records.count == 1 ? records[0].workID : nil
    }

    func noteReserved(_ workID: SyncWorkID) {
        mostRecentlyReservedWorkID = workID
    }

    func lastReservedWorkID() -> SyncWorkID? {
        mostRecentlyReservedWorkID
    }

    func remoteHeadWorkIDs() -> [SyncWorkID] {
        remoteEntries
            .compactMap { $0.work.headRevisionID == nil ? nil : $0.work.workID }
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }

    private func remoteSnapshot() async throws -> DeviceSyncRemoteLibrarySnapshot {
        guard !remoteLoadFails else { throw CloudLibraryHarnessError.unavailable }
        if shouldPauseNextRemoteLoad {
            shouldPauseNextRemoteLoad = false
            remoteLoadPaused = true
            while !resumeRemoteLoadRequested {
                try await Task.sleep(for: .milliseconds(10))
            }
            remoteLoadPaused = false
            resumeRemoteLoadRequested = false
        }
        return DeviceSyncRemoteLibrarySnapshot(entries: remoteEntries, connection: connection)
    }

    private func preparedWork(
        _ workID: SyncWorkID,
        expected: SyncWorkLibraryEntry?
    ) throws -> DeviceSyncPreparedLibraryWork {
        guard let value = resumable[workID], expected == nil || expected == value.0 else {
            throw CloudLibraryHarnessError.missingPreparedWork
        }
        return DeviceSyncPreparedLibraryWork(
            entry: value.0,
            document: value.1,
            packageSnapshot: value.2,
            bind: { _ in await self.completePrepared(workID) }
        )
    }

    private func completePrepared(_ workID: SyncWorkID) {
        guard let value = resumable.removeValue(forKey: workID) else { return }
        completed.insert(workID)
        authorities.insert(workID)
        remoteEntries = [
            DeviceSyncRemoteLibraryEntry(work: value.0, availability: .locallyBound)
        ]
    }

    private func publishFromActiveDocument(
        _ workID: SyncWorkID,
        document: NovelDocument
    ) throws {
        activeDocumentPublishCalls.append(workID)
        try publish(workID, document: document)
    }

    private func resumeInitialPublication(
        _ workID: SyncWorkID,
        document: NovelDocument
    ) async throws {
        hiddenResumeCalls.append(workID)
        if shouldPauseNextHiddenResume {
            shouldPauseNextHiddenResume = false
            hiddenResumePaused = true
            while hiddenResumePaused {
                await Task.yield()
            }
        }
        try publish(workID, document: document)
    }

    private func publish(_ workID: SyncWorkID, document: NovelDocument) throws {
        publishCalls.append(workID)
        if shouldFailNextPublish {
            shouldFailNextPublish = false
            throw CloudLibraryHarnessError.unavailable
        }
        guard connection != .accountRequired,
              connection != .differentAccount else {
            throw CloudLibraryHarnessError.unavailable
        }
        authorities.insert(workID)
        if connection == .offline {
            let descriptor = try SyncWorkDescriptor(
                workID: workID,
                sourceDocumentID: document.id,
                structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                title: document.title
            )
            remoteEntries = try [
                DeviceSyncRemoteLibraryEntry(
                    work: SyncWorkLibraryEntry(descriptor: descriptor),
                    availability: .publishPending
                )
            ]
        } else {
            let revision = try makeRevision(document: document, workID: workID)
            let entry = try SyncWorkLibraryEntry(head: revision)
            completed.insert(workID)
            remoteEntries = [DeviceSyncRemoteLibraryEntry(work: entry, availability: .locallyBound)]
        }
    }

    private func makeRevision(document: NovelDocument, workID: SyncWorkID) throws -> WorkRevision {
        try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: document),
            clientCreatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private actor ReadbackMismatchPortableRepository: PortableDocumentPackageRepository {
    private let base = NovelpkgRepository()

    func load(from url: URL) async throws -> NovelDocument {
        try await base.load(from: url)
    }

    func save(_ document: NovelDocument, to url: URL) async throws {
        try await base.save(mismatching(document), to: url)
    }

    func saveCopy(
        _ document: NovelDocument,
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        try await base.saveCopy(document, from: sourceURL, to: destinationURL)
    }

    func validatePortablePackage(at url: URL) async throws -> NovelDocument {
        try await base.validatePortablePackage(at: url)
    }

    func saveValidatedCopy(
        _ document: NovelDocument,
        from _: URL,
        to destinationURL: URL
    ) async throws {
        try await base.save(mismatching(document), to: destinationURL)
    }

    private func mismatching(_ document: NovelDocument) -> NovelDocument {
        var changed = document
        changed.title += "（readback不一致）"
        return changed
    }
}
