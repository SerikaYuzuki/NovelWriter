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
        #expect(await state.openStartupLibraryWork(
            row.reference,
            expectedSession: state.documentSessionToken
        ))
        #expect(state.documentURL == privateURL)
        #expect(await harness.publishCallCount() == 0)
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
        fixture.finishSignals()

        #expect(await collector.value == 1)
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
        runtime = try DeviceSyncProductionRuntimeBox(
            localBootstrap: AppleDeviceSyncLocalBootstrap.prepare(
                rootURL: baseURL.appendingPathComponent("metadata", isDirectory: true)
            ),
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
    private var publishCalls: [SyncWorkID] = []
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
            localWorkNeedsReview: { _, _ in false },
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
                try await self.publish(workID, document: document)
            }
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

    func seedAppOnlyRemoteIntent(document: NovelDocument, workID: SyncWorkID) async throws {
        let revision = try makeRevision(document: document, workID: workID)
        try await store.beginRemoteOpen(SyncWorkLibraryEntry(head: revision))
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

    func hideRemoteCatalog() {
        remoteEntries = []
    }

    func publishCallCount() -> Int {
        publishCalls.count
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

    private func remoteSnapshot() throws -> DeviceSyncRemoteLibrarySnapshot {
        guard !remoteLoadFails else { throw CloudLibraryHarnessError.unavailable }
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

    private func publish(_ workID: SyncWorkID, document: NovelDocument) throws {
        publishCalls.append(workID)
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
