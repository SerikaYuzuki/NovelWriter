import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import Testing

@MainActor
struct IOSSnapshotSyncV2PortableBoundaryTests {
    @Test("opened value mismatch fails closed without replacing the active editor")
    func openedValueMismatchKeepsActiveEditor() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            let original = store.document
            let opened = SyncV2OpenedWork(
                workID: WorkID(UUID()),
                document: NovelDocument.newDocument(title: "別の本文"),
                documentCreatedAt: Date(),
                generation: 1,
                snapshotID: nil
            )

            #expect(store.installSnapshotSyncV2Opened(opened, value: original) == false)
            #expect(store.document == original)
            #expect(store.syncV2ActiveWorkID != opened.workID)
        }
    }

    @Test("duplicate attachment names fail closed for install and refresh without replacing the editor")
    func duplicateAttachmentNamesFailClosed() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            let original = store.document
            let duplicateName = "same.pdf"
            let activeWorkID = try #require(store.syncV2ActiveWorkID)
            let opened = SyncV2OpenedWork(
                workID: activeWorkID,
                document: original,
                documentCreatedAt: store.documentCreatedAt,
                attachments: [
                    SyncAttachment(
                        attachmentId: UUID(), fileName: duplicateName, bytes: Data("a".utf8)
                    ),
                    SyncAttachment(
                        attachmentId: UUID(), fileName: duplicateName, bytes: Data("b".utf8)
                    )
                ],
                generation: 1,
                snapshotID: nil
            )

            #expect(store.installSnapshotSyncV2Opened(opened, value: original) == false)
            #expect(store.document == original)
            #expect(store.attachments.isEmpty)
            #expect(store.snapshotSyncOutcome == .failed)
            #expect(store.adoptV2AttachmentRecords(opened.attachments) == false)
            #expect(store.attachments.isEmpty)
        }
    }

    @Test("document transition makes delayed form mutations no-ops until it finishes")
    func delayedDocumentTransitionFreezesUI() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            let original = store.document
            let editGeneration = store.localEditGeneration
            let gate = DocumentTransitionTestGate()
            let task = Task { @MainActor in
                await store.performDocumentTransition {
                    await gate.signalStarted()
                    await gate.waitForRelease()
                }
            }

            await gate.waitForStart()
            #expect(store.isDocumentTransitionInProgress)
            store.updateDocumentTitle("遅れて届いた作品名")
            store.updateDocumentSynopsis("遅れて届いたあらすじ")
            store.addChapter()
            #expect(store.document == original)
            #expect(store.localEditGeneration == editGeneration)
            #expect(store.saveState == .saved)
            await gate.release()
            #expect(await task.value)
            #expect(store.isDocumentTransitionInProgress == false)
        }
    }

    @Test("account transition makes delayed document forms no-ops")
    func accountTransitionFreezesDocumentForms() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            let original = store.document
            let editGeneration = store.localEditGeneration

            store.syncV2AccountTransitionInProgress = true
            store.updateDocumentTitle("別アカウントへ遅れて届いた作品名")
            store.updateDocumentSynopsis("別アカウントへ遅れて届いたあらすじ")
            store.addChapter()
            store.syncV2AccountTransitionInProgress = false

            #expect(store.document == original)
            #expect(store.localEditGeneration == editGeneration)
            #expect(store.saveState == .saved)
        }
    }

    @Test("sign-out cancels pending remote-only work")
    func signOutCancelsRemoteOnlyWork() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            let activeWorkID = try #require(store.syncV2ActiveWorkID)
            let application = try #require(store.snapshotSyncV2Application)
            store.updateDocumentTitle("サインアウト直前の未保存作品名")
            let savedBeforePark = store.document
            #expect(store.saveState == .dirty)
            store.syncV2LibraryItems = [SyncV2LibraryItem(
                workID: activeWorkID,
                title: savedBeforePark.title,
                availability: .cached,
                accountState: .active
            )]
            let task = Task<Void, Never> { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {}
            }
            store.snapshotSyncV2RemoteOnlyOpenTask = task
            store.snapshotSyncV2RemoteOnlyOpenToken = UUID()
            let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "FUMINIWA-signout-export-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: exportRoot,
                withIntermediateDirectories: true
            )
            let exportURL = exportRoot.appendingPathComponent("old-account.novelpkg")
            try Data("old account manuscript".utf8).write(to: exportURL)
            store.pendingExportRootURL = exportRoot
            store.pendingExportURL = exportURL

            await store.signOutFromFuminiwa()
            #expect(store.snapshotSyncV2RemoteOnlyOpenTask == nil)
            #expect(store.snapshotSyncV2RemoteOnlyOpenToken == nil)
            #expect(task.isCancelled)
            #expect(store.syncV2ActiveWorkID == nil)
            #expect(store.syncV2LibraryItems.isEmpty)
            #expect(store.pendingExportURL == nil)
            #expect(FileManager.default.fileExists(atPath: exportRoot.path) == false)
            let reopened = try await application.openLocal(workID: activeWorkID)
            #expect(reopened.document?.title == "サインアウト直前の未保存作品名")
            store.updateDocumentTitle("棚へ戻った後の遅延入力")
            #expect(store.document == savedBeforePark)
        }
    }

    @Test("test-hosted settings and editor views retain the injected defaults store")
    func hostedViewsUseInjectedDefaults() async throws {
        try await withEnvironment { environment in
            let standardAppearance = UserDefaults.standard.string(
                forKey: IOSAppearance.preferenceKey
            )
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            let settings = IOSSettingsView(store: store, userDefaults: environment.defaults)
            let editor = IOSEditorPane(store: store, userDefaults: environment.defaults)
            #expect(settings.userDefaults === environment.defaults)
            #expect(editor.userDefaults === environment.defaults)
            #expect(store.userDefaults === environment.defaults)
            #expect(
                UserDefaults.standard.string(forKey: IOSAppearance.preferenceKey)
                    == standardAppearance
            )
        }
    }

    @Test("競合選択は新しいcheckpointやintentを作らない")
    func conflictSelectionDoesNotCheckpointAgain() async throws {
        try await withEnvironment { environment in
            let store = IOSDocumentStore(
                userDefaults: environment.defaults,
                libraryRoot: environment.root
            )
            await store.bootstrap()
            #expect(await store.makeNewDocument())
            guard let application = store.snapshotSyncV2Application,
                  let workID = store.syncV2ActiveWorkID,
                  let beforeState = await application.uiState(workID: workID),
                  case let .saved(generation, snapshotID) = beforeState.localDurability else {
                Issue.record("v2 work was not durably checkpointed")
                return
            }
            #expect(await store.refreshSnapshotHistory(for: workID))
            let beforeLocalHistoryCount = store.syncV2HistoryItems.count(where: {
                $0.source == .local
            })
            let conflict = SyncV2ConflictProjection(
                conflictID: UUID(),
                revision: 1,
                baseSnapshotID: nil,
                localSnapshotID: snapshotID,
                remoteSnapshotID: SnapshotID(data: Data("remote".utf8)),
                sourceGeneration: generation
            )
            // The UI projection is durable in production; this fixture models a
            // rendered inbox while the test runtime itself has no remote conflict.
            store.snapshotSyncState = SyncUIState(
                workID: workID,
                localDurability: beforeState.localDurability,
                remoteProgress: .needsChoice,
                conflict: conflict,
                lastTypedResult: .conflictPending
            )
            store.snapshotSyncConflict = conflict

            let displayedSelection = try #require(
                store.snapshotSyncV2DisplayedConflictSelection
            )
            #expect(
                await store.resolveSnapshotSyncV2Conflict(
                    using: .useServer,
                    expectedSelection: displayedSelection
                ) == false
            )

            let newerConflict = SyncV2ConflictProjection(
                conflictID: UUID(),
                revision: conflict.revision + 1,
                baseSnapshotID: conflict.baseSnapshotID,
                localSnapshotID: conflict.localSnapshotID,
                remoteSnapshotID: conflict.remoteSnapshotID,
                sourceGeneration: conflict.sourceGeneration
            )
            store.snapshotSyncState = SyncUIState(
                workID: workID,
                localDurability: beforeState.localDurability,
                remoteProgress: .needsChoice,
                conflict: newerConflict,
                lastTypedResult: .conflictPending
            )
            store.snapshotSyncConflict = newerConflict
            #expect(
                await store.resolveSnapshotSyncV2Conflict(
                    using: .useServer,
                    expectedSelection: displayedSelection
                ) == false
            )
            #expect(store.snapshotSyncConflict == newerConflict)
            let afterState = await application.uiState(workID: workID)
            #expect(afterState?.localDurability == beforeState.localDurability)
            #expect(await store.refreshSnapshotHistory(for: workID))
            #expect(store.syncV2HistoryItems.count(where: { $0.source == .local }) == beforeLocalHistoryCount)
        }
    }
}

extension IOSSnapshotSyncV2PortableBoundaryTests {
    @Test("import uses manifest createdAt and archives opaque package resources")
    func importUsesPortableMetadataAndArchivesOpaqueResources() async throws {
        try await withEnvironment { environment in
            let source = environment.root
                .deletingLastPathComponent()
                .appendingPathComponent("portable-source-\(UUID().uuidString).novelpkg", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: source) }
            let repository = NovelpkgRepository()
            try await repository.save(NovelDocument.newDocument(), to: source)

            let createdAtString = "2021-05-06T07:08:09.123Z"
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expectedCreatedAt = try #require(formatter.date(from: createdAtString))
            let expectedCanonicalCreatedAt = Date(
                timeIntervalSince1970: expectedCreatedAt.timeIntervalSince1970.rounded(.down)
            )
            var manifest = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: source.appendingPathComponent("manifest.json"))
                ) as? [String: Any]
            )
            manifest["createdAt"] = createdAtString
            try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys, .prettyPrinted]
            ).write(to: source.appendingPathComponent("manifest.json"))
            let opaqueBytes = Data("opaque package resource".utf8)
            try opaqueBytes.write(to: source.appendingPathComponent("opaque-resource.bin"))
            let expectedResources = [PortableResource(
                pathComponents: ["opaque-resource.bin"],
                kind: .regularFile,
                bytes: opaqueBytes
            )]

            let importedWorkID: WorkID
            do {
                let store = IOSDocumentStore(
                    userDefaults: environment.defaults,
                    libraryRoot: environment.root
                )
                await store.bootstrap()
                #expect(await store.importPackage(from: source))
                #expect(store.documentCreatedAt == expectedCanonicalCreatedAt)
                #expect(store.syncV2PortableCreatedAt == expectedCreatedAt)
                #expect(store.syncV2PortableResources == expectedResources)
                importedWorkID = try #require(store.syncV2ActiveWorkID)
            }

            // Drop the test composition so the next store opens the persisted
            // SQLite file instead of reusing the first application instance.
            await environment.releaseApplication()

            do {
                let reopenedStore = IOSDocumentStore(
                    userDefaults: environment.defaults,
                    libraryRoot: environment.root
                )
                await reopenedStore.bootstrap()
                #expect(await reopenedStore.openSnapshotSyncV2(workID: importedWorkID.rawValue))
                #expect(reopenedStore.documentCreatedAt == expectedCanonicalCreatedAt)
                #expect(reopenedStore.syncV2PortableCreatedAt == expectedCreatedAt)
                #expect(reopenedStore.syncV2PortableResources == expectedResources)

                await reopenedStore.requestExport()
                let exported = try #require(reopenedStore.pendingExportURL)
                let exportedPortable = try await SyncV2PortableBridge()
                    .importExplicitPackage(from: exported)
                #expect(exportedPortable.documentCreatedAt == expectedCreatedAt)
                #expect(exportedPortable.resources == expectedResources)
                #expect(!exportedPortable.resources.contains {
                    $0.pathComponents == SyncV2PortableMetadata.localCreatedAtPath
                })
                reopenedStore.dismissExport()
            }

            let archiveRoot = environment.root
                .appendingPathComponent("Legacy", isDirectory: true)
                .appendingPathComponent("ImportedPackages", isDirectory: true)
            let archives = try FileManager.default.contentsOfDirectory(
                at: archiveRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let archivedResource = try #require(
                archives.first?.appendingPathComponent("opaque-resource.bin")
            )
            let archivedBytes = try Data(contentsOf: archivedResource)
            #expect(archivedBytes == opaqueBytes)
        }
    }

    private func withEnvironment(
        _ body: (TestEnvironment) async throws -> Void
    ) async throws {
        let environment = makeEnvironment()
        do {
            try await body(environment)
        } catch {
            await environment.cleanup()
            throw error
        }
        await environment.cleanup()
        let key = environment.root.standardizedFileURL
        #expect(IOSDocumentStore.testRuntimeApplications[key] == nil)
        #expect(IOSDocumentStore.testRuntimeConfigurations[key] == nil)
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-v2-portable-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.v2.portable.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
private struct TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func releaseApplication() async {
        let key = root.standardizedFileURL
        IOSDocumentStore.testRuntimeApplications.removeValue(forKey: key)
        // Let in-flight actor calls release their SQLite handles before a
        // second composition opens the same isolated database.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func cleanup() async {
        let key = root.standardizedFileURL
        await releaseApplication()
        IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: key)
        // The application has no explicit worker/SQLite close API. Do not
        // unlink a database that an actor may still own; unique temporary
        // roots are reclaimed by the platform after the app-host run.
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor DocumentTransitionTestGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
