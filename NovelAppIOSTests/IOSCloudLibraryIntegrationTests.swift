import EditorKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
import NovelSyncCloudKit
import NovelSyncTesting
import Testing

@MainActor
@Suite("iOS cloud-first library", .serialized)
struct IOSCloudLibraryIntegrationTests {
    @Test("接続状態に合わせて同期状態と操作可否を正確に案内する")
    func connectionAwareLibraryStatusText() {
        #expect(IOSCloudLibraryPresentation.statusText(
            availability: .cachedRemote,
            connection: .offline
        ) == "この端末に保存済み・オフラインでも開けます")
        #expect(IOSCloudLibraryPresentation.statusText(
            availability: .cachedRemote,
            connection: .unavailable
        ) == "この端末に保存済み・iCloud状態を確認できません")
        #expect(IOSCloudLibraryPresentation.statusText(
            availability: .remoteOnly,
            connection: .offline
        ) == "接続後にこの端末へダウンロード")
        #expect(IOSCloudLibraryPresentation.statusText(
            availability: .remotePending,
            connection: .offline
        ) == "タップしてこの端末への保存を再開")
        #expect(IOSCloudLibraryPresentation.statusText(
            availability: .legacyLocal,
            connection: .accountRequired
        ) == "タップして新しい作品として取り込む")
        #expect(IOSCloudLibraryPresentation.connectionNotice(.differentAccount)
            == "前回と異なるiCloudアカウントです。この端末に保存済みの作品だけを表示し、自動では送信しません。")
    }

    @Test("production inspectionは未bindのlocal-only作品をreview扱いにしない")
    func productionInspectionAcceptsUnboundLocalOnlyWork() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .accountRequired)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "未bindの端末内作品")
        let workID = SyncWorkID()
        try await fixture.seedPublishPendingPackage(document, workID: workID)
        let bootstrap = try AppleDeviceSyncLocalBootstrap.prepare(
            rootURL: fixture.baseURL.appendingPathComponent("ProductionSync", isDirectory: true)
        )
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let box = IOSDeviceSyncProductionRuntimeBox(
            localBootstrap: bootstrap,
            privateWorkingCopyLocation: fixture.location,
            localLibraryStore: fixture.localStore,
            signalContinuation: signals.continuation
        )

        let needsReview = try await box.libraryWorkNeedsReview(
            workID: workID,
            documentID: document.id
        )

        #expect(!needsReview)
    }

    @Test("runtime bootstrap確認中は追加を止め、完了後の再読込でiCloud作品を表示する")
    func refreshAfterRuntimeBootstrapRevealsRemoteLibrary() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .checking)
        defer { fixture.cleanup() }
        let remote = NovelDocument.newDocument(title: "起動後に表示する作品")
        let workID = SyncWorkID()
        try await fixture.remote.seedRemote(remote, workID: workID)
        let store = fixture.makeStore()

        await store.bootstrap()
        #expect(store.cloudLibraryItems.isEmpty)
        #expect(!store.permitsCloudLibraryMutation)

        await fixture.remote.setConnection(.available)
        #expect(await store.refreshCloudLibrary())
        #expect(store.permitsCloudLibraryMutation)
        #expect(store.cloudLibraryItems.first?.id == workID)
        #expect(store.cloudLibraryItems.first?.availability == .remoteOnly)
    }

    @Test(
        "account未設定ではnew/importをlocal-onlyで保ちinitial publishを試さない",
        arguments: [false, true]
    )
    func accountRequiredCreationStaysLocalOnly(importsPackage: Bool) async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .accountRequired)
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(store.permitsCloudLibraryMutation)
        #expect(!store.mayAttemptInitialCloudPublish)

        let created: Bool
        if importsPackage {
            let sourceURL = fixture.baseURL.appendingPathComponent(
                "account-required-import.novelpkg",
                isDirectory: true
            )
            try await fixture.repository.save(
                NovelDocument.newDocument(title: "account未設定の取込"),
                to: sourceURL
            )
            created = await store.importCloudLibraryPackage(from: sourceURL)
        } else {
            created = await store.makeNewCloudLibraryDocument()
        }

        #expect(created)
        #expect(await fixture.remote.publishCallCount() == 0)
        let workID = try #require(store.activeCloudWorkID)
        #expect(try await fixture.localStore.record(for: workID)?.state == .publishPending)
        #expect(store.cloudLibraryItems.first(where: { $0.id == workID })?.availability == .localOnly)
    }

    @Test("stagingが残るreservationはabortせずexact intentを保持する")
    func abortReservationRejectsRemainingStagingPackage() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "stagingを保全する作品")
        let workID = SyncWorkID()
        let expected = try IOSDeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        try await fixture.localStore.reserveForPublish(
            workID: workID,
            expectedPackage: expected
        )
        let staging = try await fixture.localStore.stagingPackageURL(for: workID)
        try await fixture.repository.save(document, to: staging)

        await #expect(throws: IOSDeviceSyncLocalLibraryError.self) {
            try await fixture.localStore.abortPublishReservation(workID: workID)
        }

        let record = try #require(try await fixture.localStore.record(for: workID))
        #expect(record.state == .reservedForPublish)
        #expect(record.package == expected)
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test(
        "stagingまたはinstall直後のkillはexact packageだけをpublishPendingへ復旧する",
        arguments: [true, false]
    )
    func reservedCreationRepairsAfterRelaunch(stagingOnly: Bool) async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .accountRequired)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "途中終了から復旧する作品")
        let workID = SyncWorkID()
        let expected = try IOSDeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        try await fixture.localStore.reserveForPublish(
            workID: workID,
            expectedPackage: expected
        )
        let staging = try await fixture.localStore.stagingPackageURL(for: workID)
        try await fixture.repository.save(document, to: staging)
        if !stagingOnly {
            _ = try await fixture.localStore.installStagingPackage(staging, for: workID)
        }

        let relaunched = fixture.makeStore()
        await relaunched.bootstrap()

        let repaired = try #require(try await fixture.localStore.record(for: workID))
        #expect(repaired.state == .publishPending)
        #expect(repaired.package == expected)
        #expect(relaunched.cloudLibraryItems.first(where: { $0.id == workID })?.availability == .localOnly)
        let finalURL = try await fixture.localStore.packageURL(for: workID)
        let readback = try await fixture.repository.load(from: finalURL)
        #expect(readback == document)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(await fixture.remote.publishCallCount() == 0)
        #expect(await relaunched.openCloudLibraryWork(workID))
    }

    @Test(
        "reservationと違うstagingまたはfinalは復旧せずbytesとintentを保つ",
        arguments: [true, false]
    )
    func mismatchingReservedPackageIsNeverRepaired(stagingOnly: Bool) async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let expectedDocument = NovelDocument.newDocument(title: "予約した作品")
        let mismatchingDocument = NovelDocument.newDocument(title: "上書きしない不一致作品")
        let workID = SyncWorkID()
        let expected = try IOSDeviceSyncLocalPackageAttestation(
            document: expectedDocument,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        try await fixture.localStore.reserveForPublish(
            workID: workID,
            expectedPackage: expected
        )
        let staging = try await fixture.localStore.stagingPackageURL(for: workID)
        try await fixture.repository.save(mismatchingDocument, to: staging)
        let preservedURL: URL = if stagingOnly {
            staging
        } else {
            try await fixture.localStore.installStagingPackage(staging, for: workID)
        }

        let relaunched = fixture.makeStore()
        await relaunched.bootstrap()

        let preservedRecord = try #require(try await fixture.localStore.record(for: workID))
        #expect(preservedRecord.state == .reservedForPublish)
        #expect(preservedRecord.package == expected)
        let preservedDocument = try await fixture.repository.load(from: preservedURL)
        #expect(preservedDocument == mismatchingDocument)
        #expect(relaunched.cloudLibraryItems.first(where: { $0.id == workID })?.availability == .unavailable)
        #expect(await fixture.remote.publishCallCount() == 0)
        #expect(await relaunched.openCloudLibraryWork(workID) == false)
    }

    @Test("remote-only作品はexact revisionを固定名packageへ保存してから開く")
    func remoteOnlyWorkMaterializesAndOpens() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let remote = NovelDocument.newDocument(title: "iCloudから開く作品")
        let workID = SyncWorkID()
        try await fixture.remote.seedRemote(remote, workID: workID)
        let store = fixture.makeStore()

        await store.bootstrap()
        #expect(await store.openCloudLibraryWork(workID))

        #expect(store.startupState == .ready)
        #expect(store.document == remote)
        #expect(store.activeCloudWorkID == workID)
        let expectedURL = try await fixture.localStore.packageURL(for: workID)
        #expect(store.documentURL == expectedURL)
        #expect(try await fixture.localStore.record(for: workID)?.state == .synced)
    }

    @Test("cached row選択後にregistry stateが変わった場合は開かない")
    func cachedSelectionFailsClosedAfterRegistryStateChanges() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "選択後に状態が変わる作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedSyncedPackage(document, entry: entry)
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(store.cloudLibraryItems.first?.availability == .cachedRemote)

        try await fixture.localStore.markNeedsReview(workID: workID)

        #expect(await store.openCloudLibraryWork(workID) == false)
        #expect(store.startupState != .ready)
    }

    @Test("別accountでは既存synced copyを端末内で開き自動送信しない")
    func differentAccountOpensSyncedCopyWithoutPublishing() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .differentAccount)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "旧accountから保存済みの作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedSyncedPackage(document, entry: entry)
        let store = fixture.makeStore()

        await store.bootstrap()

        #expect(store.cloudLibraryItems.first?.availability == .accountQuarantined)
        #expect(await store.openCloudLibraryWork(workID))
        #expect(store.document == document)
        #expect(await fixture.remote.publishCallCount() == 0)
        #expect(try await fixture.localStore.record(for: workID)?.state == .synced)
    }

    @Test("耐久account隔離copyはofflineでも端末内で開き自動送信しない")
    func durableAccountQuarantineRemainsOpenableOffline() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .differentAccount)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "隔離後も端末で扱う作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedRemoteOpenPackage(document, entry: entry, completed: false)
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(await store.openCloudLibraryWork(workID))
        store.updateDocumentTitle("隔離中に端末で更新した題名")
        #expect(await store.saveNow())
        let quarantined = try #require(try await fixture.localStore.record(for: workID))
        #expect(quarantined.state == .accountQuarantined)
        #expect(quarantined.pendingRemote == nil)

        await fixture.remote.setConnection(.offline)
        await fixture.remote.hideRemoteCatalog()
        let relaunched = fixture.makeStore()
        await relaunched.bootstrap()

        #expect(relaunched.cloudLibraryItems.first?.availability == .accountQuarantined)
        #expect(await relaunched.openCloudLibraryWork(workID))
        #expect(relaunched.document.title == "隔離中に端末で更新した題名")
        #expect(await fixture.remote.publishCallCount() == 0)
    }

    @Test("journalにreview payloadがあるpublishPending作品は再起動後も開ける")
    func publishPendingReviewRowUsesFreshJournalProof() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "競合確認が必要な作品")
        let workID = SyncWorkID()
        try await fixture.seedPublishPendingPackage(document, workID: workID)
        await fixture.remote.setLocalWorkNeedsReview(true)
        let store = fixture.makeStore()

        await store.bootstrap()

        #expect(store.cloudLibraryItems.first?.availability == .needsReview)
        #expect(await store.openCloudLibraryWork(workID))
        #expect(store.document == document)
    }

    @Test("account隔離row選択後にpendingへ戻った場合はstale openしない")
    func quarantinedSelectionFailsClosedAfterPendingRestoration() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .differentAccount)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "隔離中の作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedRemoteOpenPackage(document, entry: entry, completed: false)
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(store.cloudLibraryItems.first?.availability == .accountQuarantined)

        try await fixture.localStore.restoreRemoteOpenPending(
            workID: workID,
            expectedRemote: entry
        )

        #expect(await store.openCloudLibraryWork(workID) == false)
        #expect(store.startupState != .ready)
    }

    @Test("既存finalがremote revisionと違う場合は上書きせずreview隔離する")
    func mismatchingExistingFinalIsNeverOverwritten() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let remote = NovelDocument.newDocument(title: "iCloudの正しい題名")
        var local = remote
        local.title = "端末に残す不一致内容"
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(remote, workID: workID)
        try await fixture.localStore.beginRemoteOpen(entry)
        let finalURL = try await fixture.localStore.packageURL(for: workID)
        try await fixture.repository.save(local, to: finalURL)
        let store = fixture.makeStore()

        await store.bootstrap()
        let opened = await store.openCloudLibraryWork(workID)
        #expect(!opened)

        #expect(try await fixture.repository.validatePortablePackage(at: finalURL) == local)
        #expect(try await fixture.localStore.record(for: workID)?.state == .needsReview)
        #expect(store.cloudLibraryItems.first(where: { $0.id == workID })?.availability == .needsReview)
        #expect(await store.openCloudLibraryWork(workID))
        #expect(store.document == local)
        #expect(try await fixture.repository.validatePortablePackage(at: finalURL) == local)
        #expect(await fixture.remote.publishCallCount() == 0)
    }

    @Test("remote headが変わったsynced作品はlocal copyを上書きせずreviewとして開く")
    func syncedRemoteMismatchOpensExactLocalCopyForReview() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let localDocument = NovelDocument.newDocument(title: "端末の同期済み作品")
        let workID = SyncWorkID()
        let acknowledged = try await fixture.remote.seedRemote(
            localDocument,
            workID: workID
        )
        try await fixture.seedSyncedPackage(localDocument, entry: acknowledged)
        var remoteDocument = localDocument
        remoteDocument.title = "別端末で更新された題名"
        _ = try await fixture.remote.seedRemote(remoteDocument, workID: workID)
        let finalURL = try await fixture.localStore.packageURL(for: workID)
        let store = fixture.makeStore()

        await store.bootstrap()

        #expect(store.cloudLibraryItems.first?.availability == .needsReview)
        #expect(await store.openCloudLibraryWork(workID))
        #expect(store.document == localDocument)
        #expect(try await fixture.repository.load(from: finalURL) == localDocument)
        #expect(await fixture.remote.publishCallCount() == 0)
    }

    @Test("bind後account切替したdownload copyは耐久隔離して保存できる")
    func accountSwitchQuarantinesPendingDownloadDurably() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .differentAccount)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "旧アカウントの端末コピー")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedRemoteOpenPackage(document, entry: entry, completed: false)
        let store = fixture.makeStore()

        await store.bootstrap()
        let row = try #require(store.cloudLibraryItems.first(where: { $0.id == workID }))
        #expect(row.availability == .accountQuarantined)
        #expect(try await fixture.localStore.record(for: workID)?.state == .accountQuarantined)
        #expect(await store.openCloudLibraryWork(workID))

        store.updateDocumentTitle("端末で追記した題名")
        #expect(await store.saveNow())
        let record = try #require(try await fixture.localStore.record(for: workID))
        #expect(record.state == .accountQuarantined)
        #expect(record.package?.titleProjection == "端末で追記した題名")
        #expect(await fixture.remote.publishCallCount() == 0)
    }

    @Test("bind前のaccount切替はexact pendingを保ち元scope復帰後にresumeする")
    func accountQuarantineResumesWhenOriginalScopeReturns() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .differentAccount)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "元scopeへ戻して開く作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedRemoteOpenPackage(document, entry: entry, completed: false)
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(try await fixture.localStore.record(for: workID)?.state == .accountQuarantined)
        #expect(try await fixture.localStore.record(for: workID)?.pendingRemote == entry)

        await fixture.remote.setConnection(.available)
        #expect(await store.refreshCloudLibrary())
        #expect(store.cloudLibraryItems.first(where: { $0.id == workID })?.availability == .remotePending)
        #expect(try await fixture.localStore.record(for: workID)?.state == .remoteOpenPending)
        #expect(await store.openCloudLibraryWork(workID))
        #expect(try await fixture.localStore.record(for: workID)?.state == .synced)
    }

    @Test("journal検査失敗はreview payloadを偽装せずopen不能にする")
    func journalInspectionFailureFailsClosed() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "journalを読めない作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedSyncedPackage(document, entry: entry)
        await fixture.remote.setJournalInspectionFailure(true)
        let store = fixture.makeStore()

        await store.bootstrap()

        let row = try #require(store.cloudLibraryItems.first(where: { $0.id == workID }))
        #expect(row.availability == .unavailable)
        let opened = await store.openCloudLibraryWork(workID)
        #expect(!opened)
    }

    @Test("package無しpendingは別accountで題名もopen導線も公開しない")
    func packageLessPendingIsHiddenAcrossAccountSwitch() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .differentAccount)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "表示してはいけない旧作品名")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.localStore.beginRemoteOpen(entry)
        await fixture.remote.setResumable(workID, true)
        let store = fixture.makeStore()

        await store.bootstrap()

        #expect(!store.cloudLibraryItems.contains(where: { $0.id == workID }))
        let opened = await store.openCloudLibraryWork(workID)
        #expect(!opened)
    }

    @Test("bind後registry mark前のkillはsame-scope offline証拠で同期済みに復旧する")
    func offlineRelaunchRecoversBoundRemoteOpen() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .offline)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "オフライン復旧する作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedRemoteOpenPackage(document, entry: entry, completed: true)
        await fixture.remote.hideRemoteCatalog()
        let store = fixture.makeStore()

        await store.bootstrap()

        #expect(try await fixture.localStore.record(for: workID)?.state == .synced)
        #expect(store.cloudLibraryItems.first(where: { $0.id == workID })?.availability == .cachedRemote)
        #expect(store.cloudLibraryConnection == .offline)
    }

    @Test("旧hidden packageは明示取り込みで新WorkIDへ複製し原本bytesを保全する")
    func legacyPrivatePackageIsExplicitlyRecovered() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let legacyWorkID = SyncWorkID()
        let legacyURL = try await fixture.localStore.packageURL(for: legacyWorkID)
        let document = NovelDocument.newDocument(title: "旧iOS作品")
        try await fixture.repository.save(document, to: legacyURL)
        let attachmentSource = fixture.baseURL.appendingPathComponent("資料.txt")
        let attachmentBytes = Data("旧作品の資料".utf8)
        try attachmentBytes.write(to: attachmentSource)
        let attachment = try await fixture.repository.addAttachment(
            from: attachmentSource,
            to: legacyURL
        )
        let originalAttachmentURL = fixture.repository.attachmentURL(
            named: attachment.fileName,
            in: legacyURL
        )
        let store = fixture.makeStore()

        await store.bootstrap()
        let recovery = try #require(store.cloudLibraryItems.first(where: { $0.id == legacyWorkID }))
        #expect(recovery.availability == .legacyLocal)
        #expect(await store.openCloudLibraryWork(legacyWorkID))

        let newWorkID = try #require(store.activeCloudWorkID)
        #expect(newWorkID != legacyWorkID)
        #expect(try Data(contentsOf: originalAttachmentURL) == attachmentBytes)
        #expect(try await fixture.localStore.record(for: legacyWorkID)?.state == .legacyPreserved)
        #expect(try await fixture.localStore.record(for: newWorkID) != nil)

        let relaunched = fixture.makeStore()
        await relaunched.bootstrap()
        #expect(!relaunched.cloudLibraryItems.contains(where: { $0.id == legacyWorkID }))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("未登録local packageと同じWorkIDのremote作品を自動結合せず明示復旧する")
    func legacyPackageCollisionNeverBindsOrOverwritesAutomatically() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let collidedWorkID = SyncWorkID()
        let remoteDocument = NovelDocument.newDocument(title: "iCloud側の別作品")
        let remoteEntry = try await fixture.remote.seedRemote(
            remoteDocument,
            workID: collidedWorkID
        )
        let localDocument = NovelDocument.newDocument(title: "端末に残っていた旧作品")
        let localURL = try await fixture.localStore.packageURL(for: collidedWorkID)
        try await fixture.repository.save(localDocument, to: localURL)
        let store = fixture.makeStore()

        await store.bootstrap()

        let collision = try #require(store.cloudLibraryItems.first(where: {
            $0.id == collidedWorkID
        }))
        #expect(collision.availability == .legacyLocal)
        #expect(try await fixture.repository.load(from: localURL) == localDocument)
        #expect(try await fixture.localStore.record(for: collidedWorkID) == nil)

        #expect(await store.openCloudLibraryWork(collidedWorkID))
        let recoveredWorkID = try #require(store.activeCloudWorkID)
        #expect(recoveredWorkID != collidedWorkID)
        #expect(try await fixture.repository.load(from: localURL) == localDocument)
        #expect(try await fixture.localStore.record(for: collidedWorkID)?.state == .legacyPreserved)
        let remoteAfterRecovery = try await fixture.remote.loadRemoteLibrary()
        #expect(remoteAfterRecovery.entries.first(where: {
            $0.work.workID == collidedWorkID
        })?.work == remoteEntry)
    }

    @Test("旧作品の明示復旧は完了までsingle-flightを保持する")
    func concurrentLegacyRecoveryCreatesOnlyOneNewWork() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let legacyWorkID = SyncWorkID()
        let legacyURL = try await fixture.localStore.packageURL(for: legacyWorkID)
        try await fixture.repository.save(
            NovelDocument.newDocument(title: "二重取り込みを防ぐ旧作品"),
            to: legacyURL
        )
        let store = fixture.makeStore()
        await store.bootstrap()
        await fixture.remote.pauseNextLegacyRecoveryMark()

        let firstOpen = Task { @MainActor in
            await store.openCloudLibraryWork(legacyWorkID)
        }
        await waitUntil { await fixture.remote.legacyRecoveryMarkIsPaused() }

        #expect(await store.openCloudLibraryWork(legacyWorkID) == false)
        await fixture.remote.resumeLegacyRecoveryMark()
        #expect(await firstOpen.value)

        let inventory = try await fixture.localStore.inventory()
        #expect(inventory.records.count(where: { $0.workID != legacyWorkID }) == 1)
        #expect(await fixture.remote.publishCallCount() == 1)
        #expect(try await fixture.localStore.record(for: legacyWorkID)?.state == .legacyPreserved)
    }

    @Test("silent wrong-writeはdisk readback不一致でregistry確定を止める")
    func packageMutationUsesExactDiskReadback() async throws {
        let fixture = try IOSCloudLibraryFixture(
            connection: .available,
            repository: IOSWrongWritePortableRepository()
        )
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "保存前の題名")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedSyncedPackage(document, entry: entry)
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(await store.openCloudLibraryWork(workID))
        let before = try #require(try await fixture.localStore.record(for: workID)?.package)

        store.updateDocumentTitle("保存要求の題名")
        let saved = await store.saveNow()
        #expect(!saved)

        let after = try #require(try await fixture.localStore.record(for: workID)?.package)
        #expect(after == before)
        #expect(after.titleProjection == "保存前の題名")
    }

    @Test("exportはportable validated copyで資料を保ちactive sessionを変えない")
    func exportPreservesResourcesAndActiveIdentity() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "書き出す作品")
        let workID = SyncWorkID()
        let entry = try await fixture.remote.seedRemote(document, workID: workID)
        try await fixture.seedSyncedPackage(document, entry: entry)
        let packageURL = try await fixture.localStore.packageURL(for: workID)
        let source = fixture.baseURL.appendingPathComponent("export-resource.txt")
        let resource = Data("portable resource".utf8)
        try resource.write(to: source)
        let attachment = try await fixture.repository.addAttachment(from: source, to: packageURL)
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(await store.openCloudLibraryWork(workID))
        let session = try #require(store.currentDocumentSessionToken)
        let registryBefore = try await fixture.localStore.record(for: workID)

        await store.requestExport()

        let exportURL = try #require(store.pendingExportURL)
        #expect(try await fixture.repository.validatePortablePackage(at: exportURL) == document)
        let exportedAttachments = try await fixture.repository.listAttachments(in: exportURL)
        #expect(exportedAttachments == [attachment])
        let exportedResourceURL = fixture.repository.attachmentURL(
            named: attachment.fileName,
            in: exportURL
        )
        #expect(try Data(contentsOf: exportedResourceURL) == resource)
        #expect(store.currentDocumentSessionToken == session)
        #expect(store.documentURL == packageURL)
        #expect(store.activeCloudWorkID == workID)
        #expect(try await fixture.localStore.record(for: workID) == registryBefore)
        store.dismissExport()
    }

    @Test("active WorkID lookup失敗時はpendingをhidden coordinatorで再送しない")
    func activeLookupFailureStopsBackgroundRetry() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available)
        defer { fixture.cleanup() }
        let document = NovelDocument.newDocument(title: "再送を止める作品")
        let workID = SyncWorkID()
        try await fixture.seedPublishPendingPackage(document, workID: workID)
        await fixture.remote.setAuthority(workID, true)
        await fixture.remote.setWorkIDLookupFailure(true)
        let store = fixture.makeStore()

        await store.bootstrap()

        #expect(await fixture.remote.hiddenResumeCallCount() == 0)
        #expect(try await fixture.localStore.record(for: workID)?.state == .publishPending)
    }

    @Test("remote signal stormは実行中一回と追随一回へcoalesceする")
    func remoteSignalStormCoalescesLibraryRefresh() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .available, withSignals: true)
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.bootstrap()
        #expect(await fixture.remote.remoteLoadCallCount() == 1)
        await fixture.remote.pauseNextRemoteLoad()

        fixture.signal()
        await waitUntil { await fixture.remote.remoteLoadIsPaused() }
        for _ in 0 ..< 8 {
            fixture.signal()
        }
        await fixture.remote.resumePausedRemoteLoad()
        await waitUntil { await fixture.remote.remoteLoadCallCount() == 3 }

        #expect(await fixture.remote.remoteLoadCallCount() == 3)
    }

    @Test("cold Open WithはCloud bootstrap完了を待って一度だけ取り込む")
    func coldExternalOpenWaitsForCloudReadiness() async throws {
        let fixture = try IOSCloudLibraryFixture(connection: .checking)
        defer { fixture.cleanup() }
        let sourceURL = fixture.baseURL.appendingPathComponent(
            "cold-open.novelpkg",
            isDirectory: true
        )
        let source = NovelDocument.newDocument(title: "起動直後に渡された作品")
        try await fixture.repository.save(source, to: sourceURL)
        let store = fixture.makeStore()

        let opening = Task { @MainActor in
            await store.handleExternalPackageURL(sourceURL)
        }
        await waitUntil { await fixture.remote.remoteLoadCallCount() >= 1 }
        await fixture.remote.setConnection(.available)

        #expect(await opening.value)
        #expect(store.document == source)
        #expect(store.activeCloudWorkID != nil)
        #expect(await fixture.remote.publishCallCount() == 1)
    }
}

private enum IOSCloudLibraryTestError: Error {
    case unavailable
    case injected
}

private final class IOSCloudLibraryFixture: @unchecked Sendable {
    let baseURL: URL
    let repository: NovelpkgRepository
    let appRepository: any PortableDocumentPackageRepository
    let location: IOSPrivateWorkingCopyLocation
    let localStore: IOSDeviceSyncLocalLibraryStore
    let remote: IOSCloudLibraryRemoteHarness
    let defaults: UserDefaults
    private let defaultsSuite: String
    private let signalContinuation: AsyncStream<Void>.Continuation?
    private let signals: AsyncStream<Void>?

    init(
        connection: IOSDeviceSyncLibraryConnection,
        repository: (any PortableDocumentPackageRepository)? = nil,
        withSignals: Bool = false
    ) throws {
        let identifier = UUID().uuidString
        baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FUMINIWA-iOS-Cloud-Library-\(identifier)",
            isDirectory: true
        )
        let works = baseURL.appendingPathComponent("Works", isDirectory: true)
        location = try IOSPrivateWorkingCopyLocation.prepareInjectedLibraryRoot(works)
        localStore = try IOSDeviceSyncLocalLibraryStore(
            registryRootURL: baseURL.appendingPathComponent("Registry", isDirectory: true),
            trustedAncestorURL: FileManager.default.temporaryDirectory,
            workingCopyLocation: location
        )
        let concreteRepository = NovelpkgRepository()
        self.repository = concreteRepository
        appRepository = repository ?? concreteRepository
        remote = IOSCloudLibraryRemoteHarness(connection: connection)
        defaultsSuite = "dev.serikayuzuki.fuminiwa.ios.cloud-tests.\(identifier)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        if withSignals {
            let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(16))
            signals = pair.stream
            signalContinuation = pair.continuation
        } else {
            signals = nil
            signalContinuation = nil
        }
    }

    @MainActor
    func makeStore() -> IOSDocumentStore {
        IOSDocumentStore(
            repository: appRepository,
            userDefaults: defaults,
            deviceSyncRuntime: makeRuntime(),
            privateWorkingCopyLocation: location
        )
    }

    func signal() {
        signalContinuation?.yield()
    }

    func cleanup() {
        signalContinuation?.finish()
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: baseURL)
    }

    func seedRemoteOpenPackage(
        _ document: NovelDocument,
        entry: SyncWorkLibraryEntry,
        completed: Bool
    ) async throws {
        try await localStore.beginRemoteOpen(entry)
        let url = try await localStore.packageURL(for: entry.workID)
        try await repository.save(document, to: url)
        let attestation = try IOSDeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        try await localStore.attestRemotePackage(
            workID: entry.workID,
            package: attestation,
            expectedRemote: entry
        )
        if completed {
            await remote.markCompleted(entry.workID)
        }
    }

    func seedSyncedPackage(
        _ document: NovelDocument,
        entry: SyncWorkLibraryEntry
    ) async throws {
        try await seedRemoteOpenPackage(document, entry: entry, completed: true)
        try await localStore.markSynced(workID: entry.workID, acknowledgedRemote: entry)
    }

    func seedPublishPendingPackage(
        _ document: NovelDocument,
        workID: SyncWorkID
    ) async throws {
        let attestation = try IOSDeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        try await localStore.reserveForPublish(workID: workID, expectedPackage: attestation)
        let url = try await localStore.packageURL(for: workID)
        try await repository.save(document, to: url)
        try await localStore.confirmPublishPackage(workID: workID, package: attestation)
    }

    private func makeRuntime() -> IOSDeviceSyncRuntime {
        let library = IOSDeviceSyncLibraryRuntime(
            loadLocalInventory: { try await self.localStore.inventory() },
            loadRemoteLibrary: { try await self.remote.loadRemoteLibrary() },
            packageURL: { try await self.localStore.packageURL(for: $0) },
            workIDForPackageURL: {
                if await self.remote.workIDLookupShouldFail() {
                    throw IOSCloudLibraryTestError.injected
                }
                return try await self.localStore.workID(for: $0)
            },
            stagingPackageURL: { try await self.localStore.stagingPackageURL(for: $0) },
            validateStagingPackage: {
                try await self.localStore.validateStagingPackage(at: $0, for: $1)
            },
            installStagingPackage: {
                try await self.localStore.installStagingPackage($0, for: $1)
            },
            discardStagingPackage: {
                try await self.localStore.discardStagingPackage($0, for: $1)
            },
            validateInstalledPackage: {
                try await self.localStore.validateInstalledPackage(for: $0)
            },
            reserveForPublish: {
                try await self.localStore.reserveForPublish(workID: $0, expectedPackage: $1)
            },
            abortPublishReservation: {
                try await self.localStore.abortPublishReservation(workID: $0)
            },
            confirmPublishPackage: {
                try await self.localStore.confirmPublishPackage(workID: $0, package: $1)
            },
            beginRemoteOpen: { try await self.localStore.beginRemoteOpen($0) },
            attestRemotePackage: {
                try await self.localStore.attestRemotePackage(
                    workID: $0,
                    package: $1,
                    expectedRemote: $2
                )
            },
            prepareRemoteOpen: { try await self.remote.preparedWork($0) },
            resumeRemoteOpen: { try await self.remote.resumedWork($0) },
            canResumeRemoteOpenOffline: { await self.remote.canResume($0) },
            offlineResumableRemoteOpenWorkIDs: { await self.remote.resumableWorkIDs() },
            hasCompletedRemoteOpenLocally: { await self.remote.hasCompleted($0) },
            localWorkNeedsReview: { _, _ in try await self.remote.localWorkNeedsReview() },
            markSynced: {
                try await self.localStore.markSynced(workID: $0, acknowledgedRemote: $1)
            },
            markNeedsReview: { try await self.localStore.markNeedsReview(workID: $0) },
            quarantineInstalledPackage: {
                try await self.localStore.quarantineInstalledPackage(workID: $0, package: $1)
            },
            quarantineForAccount: {
                try await self.localStore.quarantineForAccount(workID: $0, package: $1)
            },
            restoreRemoteOpenPending: {
                try await self.localStore.restoreRemoteOpenPending(workID: $0, expectedRemote: $1)
            },
            markLegacyPackageRecovered: {
                await self.remote.pauseLegacyRecoveryMarkIfNeeded()
                try await self.localStore.markLegacyPackageRecovered(workID: $0, package: $1)
            },
            recordPackageMutation: {
                try await self.localStore.recordPackageMutation(workID: $0, package: $1)
            },
            hasLocalPublishAuthority: { workID, _ in
                await self.remote.hasAuthority(workID)
            },
            publishNewWork: { workID, document, _ in
                try await self.remote.publish(document, workID: workID, hidden: false)
            },
            resumeInitialWorkPublication: { workID, document, _ in
                try await self.remote.publish(document, workID: workID, hidden: true)
            }
        )
        return IOSDeviceSyncRuntime(
            replicaID: SyncReplicaID(),
            transport: InMemoryEpisodeSyncServer(),
            workTransport: InMemoryWorkSyncServer(),
            localWorkBinding: { _, _, _ in nil },
            binding: { _, _, _ in nil },
            remoteChangeSignals: signals,
            library: library,
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }
}

private actor IOSCloudLibraryRemoteHarness {
    private var connection: IOSDeviceSyncLibraryConnection
    private var entries: [SyncWorkID: IOSDeviceSyncRemoteLibraryEntry] = [:]
    private var documents: [SyncWorkID: NovelDocument] = [:]
    private var resumable: Set<SyncWorkID> = []
    private var completed: Set<SyncWorkID> = []
    private var authorities: Set<SyncWorkID> = []
    private var publishCalls = 0
    private var hiddenResumeCalls = 0
    private var journalInspectionFails = false
    private var journalNeedsReview = false
    private var lookupFails = false
    private var remoteLoadCalls = 0
    private var shouldPauseNextRemoteLoad = false
    private var remoteLoadPaused = false
    private var resumeRemoteLoadRequested = false
    private var shouldPauseNextLegacyRecoveryMark = false
    private var legacyRecoveryMarkPaused = false
    private var resumeLegacyRecoveryMarkRequested = false

    init(connection: IOSDeviceSyncLibraryConnection) {
        self.connection = connection
    }

    func setConnection(_ connection: IOSDeviceSyncLibraryConnection) {
        self.connection = connection
    }

    @discardableResult
    func seedRemote(_ document: NovelDocument, workID: SyncWorkID) throws -> SyncWorkLibraryEntry {
        let revision = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: document),
            clientCreatedAt: Date(timeIntervalSince1970: 1000)
        )
        let entry = try SyncWorkLibraryEntry(head: revision)
        entries[workID] = IOSDeviceSyncRemoteLibraryEntry(
            work: entry,
            availability: completed.contains(workID) ? .locallyBound : .remoteOnly
        )
        documents[workID] = document
        return entry
    }

    func hideRemoteCatalog() {
        entries = [:]
    }

    func loadRemoteLibrary() async throws -> IOSDeviceSyncRemoteLibrarySnapshot {
        remoteLoadCalls += 1
        if shouldPauseNextRemoteLoad {
            shouldPauseNextRemoteLoad = false
            remoteLoadPaused = true
            for _ in 0 ..< 200 {
                if resumeRemoteLoadRequested {
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            remoteLoadPaused = false
            resumeRemoteLoadRequested = false
        }
        return IOSDeviceSyncRemoteLibrarySnapshot(
            entries: entries.values.sorted {
                $0.work.workID.rawValue.uuidString < $1.work.workID.rawValue.uuidString
            },
            connection: connection
        )
    }

    func preparedWork(_ expected: SyncWorkLibraryEntry) throws -> IOSDeviceSyncPreparedLibraryWork {
        guard entries[expected.workID]?.work == expected,
              let document = documents[expected.workID] else {
            throw IOSCloudLibraryTestError.unavailable
        }
        let expectedSnapshot = try WorkSnapshot(document: document)
        return IOSDeviceSyncPreparedLibraryWork(
            entry: expected,
            document: document,
            packageSnapshot: expectedSnapshot,
            bind: { snapshot in
                guard snapshot == expectedSnapshot else {
                    throw IOSCloudLibraryTestError.injected
                }
                await self.markCompleted(expected.workID)
            }
        )
    }

    func resumedWork(_ workID: SyncWorkID) throws -> IOSDeviceSyncPreparedLibraryWork {
        guard let entry = entries[workID]?.work else {
            throw IOSCloudLibraryTestError.unavailable
        }
        return try preparedWork(entry)
    }

    func markCompleted(_ workID: SyncWorkID) {
        completed.insert(workID)
        if let current = entries[workID] {
            entries[workID] = IOSDeviceSyncRemoteLibraryEntry(
                work: current.work,
                availability: .locallyBound
            )
        }
    }

    func hasCompleted(_ entry: SyncWorkLibraryEntry) -> Bool {
        completed.contains(entry.workID)
    }

    func setResumable(_ workID: SyncWorkID, _ value: Bool) {
        if value {
            resumable.insert(workID)
        } else {
            resumable.remove(workID)
        }
    }

    func canResume(_ workID: SyncWorkID) -> Bool {
        resumable.contains(workID)
    }

    func resumableWorkIDs() -> [SyncWorkID] {
        Array(resumable)
    }

    func setAuthority(_ workID: SyncWorkID, _ value: Bool) {
        if value {
            authorities.insert(workID)
        } else {
            authorities.remove(workID)
        }
    }

    func hasAuthority(_ workID: SyncWorkID) -> Bool {
        authorities.contains(workID)
    }

    func publish(_ document: NovelDocument, workID: SyncWorkID, hidden: Bool) throws {
        publishCalls += 1
        if hidden {
            hiddenResumeCalls += 1
        }
        switch connection {
        case .available:
            authorities.insert(workID)
            _ = try seedRemote(document, workID: workID)
            markCompleted(workID)
        case .offline:
            authorities.insert(workID)
            throw IOSCloudLibraryTestError.unavailable
        case .checking, .accountRequired, .differentAccount:
            throw IOSCloudLibraryTestError.unavailable
        }
    }

    func publishCallCount() -> Int {
        publishCalls
    }

    func hiddenResumeCallCount() -> Int {
        hiddenResumeCalls
    }

    func setJournalInspectionFailure(_ value: Bool) {
        journalInspectionFails = value
    }

    func setLocalWorkNeedsReview(_ value: Bool) {
        journalNeedsReview = value
    }

    func localWorkNeedsReview() throws -> Bool {
        if journalInspectionFails {
            throw IOSCloudLibraryTestError.injected
        }
        return journalNeedsReview
    }

    func setWorkIDLookupFailure(_ value: Bool) {
        lookupFails = value
    }

    func workIDLookupShouldFail() -> Bool {
        lookupFails
    }

    func remoteLoadCallCount() -> Int {
        remoteLoadCalls
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

    func pauseNextLegacyRecoveryMark() {
        shouldPauseNextLegacyRecoveryMark = true
        resumeLegacyRecoveryMarkRequested = false
    }

    func pauseLegacyRecoveryMarkIfNeeded() async {
        guard shouldPauseNextLegacyRecoveryMark else { return }
        shouldPauseNextLegacyRecoveryMark = false
        legacyRecoveryMarkPaused = true
        for _ in 0 ..< 200 {
            if resumeLegacyRecoveryMarkRequested {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        legacyRecoveryMarkPaused = false
        resumeLegacyRecoveryMarkRequested = false
    }

    func legacyRecoveryMarkIsPaused() -> Bool {
        legacyRecoveryMarkPaused
    }

    func resumeLegacyRecoveryMark() {
        resumeLegacyRecoveryMarkRequested = true
    }
}

private actor IOSWrongWritePortableRepository: PortableDocumentPackageRepository {
    private let base = NovelpkgRepository()

    func load(from url: URL) async throws -> NovelDocument {
        try await base.load(from: url)
    }

    func save(_ document: NovelDocument, to url: URL) async throws {
        var wrong = document
        wrong.title += "（diskだけ不一致）"
        try await base.save(wrong, to: url)
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
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        try await base.saveValidatedCopy(document, from: sourceURL, to: destinationURL)
    }
}

private func waitUntil(
    attempts: Int = 200,
    condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0 ..< attempts {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("条件が期限内に成立しませんでした。")
}
