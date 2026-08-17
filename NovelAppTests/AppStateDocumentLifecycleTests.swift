import Foundation
@testable import FUMINIWA
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import Testing

@MainActor
struct AppStateDocumentLifecycleTests {
    @Test("openはpackageを明示importしWorkID sessionとSQLiteへ切り替える")
    func openUsesV2SessionAndLocalCheckpoint() async throws {
        let repository = NovelpkgRepository()
        let sourceURL = temporaryPackageURL("open")
        let document = NovelDocument.newDocument(title: "取り込み作品")
        try await repository.save(document, to: sourceURL)
        let state = try makeState(repository: repository)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()

        #expect(await state.openExternalDocument(at: sourceURL))
        #expect(state.document == document)
        let activeWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        #expect(state.snapshotSyncV2Session?.workID == activeWorkID)
        #expect(activeWorkID.rawValue != document.id)
        #expect(state.userDefaults.string(forKey: "fuminiwa.v2.activeWorkID") == activeWorkID.rawValue.uuidString)
    }

    @Test("package import失敗は現在作品を保持しrecoveryへは自動fallbackしない")
    func failedImportKeepsCurrentWork() async throws {
        let state = try makeState()
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let before = state.document
        let missingURL = temporaryPackageURL("missing")

        #expect(await state.openExternalDocument(at: missingURL) == false)
        #expect(state.document == before)
        #expect(state.startupState == .ready)
    }

    @Test("import checkpoint失敗時はdirtyな現在作品を保持する")
    func failedImportedCheckpointKeepsCurrentWork() async throws {
        let repository = NovelpkgRepository()
        let sourceURL = temporaryPackageURL("checkpoint-failure")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let importedTitle = "checkpoint-failure-import"
        try await repository.save(NovelDocument.newDocument(title: importedTitle), to: sourceURL)

        let state = try makeState(
            repository: repository,
            account: TestAccount(accountID: "checkpoint-failure-account", accountFence: "checkpoint-failure-fence"),
            checkpointOverride: { application, workID, document, reason, createdAt, attachments, resources in
                guard document.title != importedTitle else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                return try await application.checkpoint(
                    workID: workID,
                    document: document,
                    reason: reason,
                    documentCreatedAt: createdAt,
                    attachments: attachments,
                    resources: resources
                )
            }
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let application = try #require(state.snapshotSyncV2Application)
        let oldWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let oldSession = state.documentSessionToken
        state.updateSelectedEpisodeContent("Aのdirty本文")

        #expect(await state.openExternalDocument(at: sourceURL) == false)
        #expect(state.snapshotSyncV2ActiveWorkID == oldWorkID)
        #expect(state.documentSessionToken == oldSession)
        #expect(state.document.selectedEpisodeContentForTest == "Aのdirty本文")
        #expect(state.startupState == .ready)
        let reopened = try await application.open(workID: oldWorkID)
        #expect(reopened.document?.selectedEpisodeContentForTest == "Aのdirty本文")
    }

    @Test("新規作品のcheckpoint失敗時は現在作品を置換しない")
    func failedNewWorkCheckpointKeepsCurrentWork() async throws {
        let state = try makeState(
            account: TestAccount(accountID: "new-work-failure-account", accountFence: "new-work-failure-fence"),
            checkpointOverride: { application, workID, document, reason, createdAt, attachments, resources in
                guard reason != .navigation else {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
                return try await application.checkpoint(
                    workID: workID,
                    document: document,
                    reason: reason,
                    documentCreatedAt: createdAt,
                    attachments: attachments,
                    resources: resources
                )
            }
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let application = try #require(state.snapshotSyncV2Application)
        let oldWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let oldSession = state.documentSessionToken
        state.updateSelectedEpisodeContent("Aのdirty本文")
        #expect(state.saveState == .unsaved)

        #expect(await state.createNewV2Document() == false)
        #expect(state.snapshotSyncV2ActiveWorkID == oldWorkID)
        #expect(state.documentSessionToken == oldSession)
        #expect(state.document.selectedEpisodeContentForTest == "Aのdirty本文")
        #expect(state.startupState == .ready)

        let reopened = try await application.open(workID: oldWorkID)
        #expect(reopened.document?.selectedEpisodeContentForTest == "Aのdirty本文")
    }

    @Test("新規作品はWorkIDを更新しSQLite checkpointだけをawaitする")
    func newWorkSwitchesSession() async throws {
        let state = try makeState()
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let oldDocumentID = state.document.id
        let oldWorkID = state.snapshotSyncV2ActiveWorkID

        await state.createNewV2Document()

        #expect(state.document.id != oldDocumentID)
        let activeWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        #expect(activeWorkID != oldWorkID)
        #expect(state.snapshotSyncV2Session?.workID == activeWorkID)
        #expect(activeWorkID.rawValue != state.document.id)
        #expect(state.userDefaults.string(forKey: "fuminiwa.v2.activeWorkID") == activeWorkID.rawValue.uuidString)
    }

    @Test("作品一覧へ戻る境界はdirty本文を先にSQLiteへ保存し別作品から再開できる")
    func libraryBoundaryCheckpointsDirtyEditorBeforeOpeningAnotherWork() async throws {
        let state = try makeState(
            account: TestAccount(accountID: "library-boundary-account", accountFence: "library-boundary-fence")
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let application = try #require(state.snapshotSyncV2Application)
        let firstWorkID = try #require(state.snapshotSyncV2ActiveWorkID)

        let secondWorkID = WorkID(UUID())
        let secondDocument = NovelDocument.newDocument(title: "別作品")
        _ = try await application.checkpoint(
            workID: secondWorkID,
            document: secondDocument,
            reason: .migration,
            documentCreatedAt: Date()
        )
        #expect(secondWorkID != firstWorkID)
        let firstWork = StartupLibraryWork(
            id: firstWorkID.rawValue,
            title: state.document.title,
            availability: .local,
            workID: firstWorkID,
            remoteProgress: .idle
        )
        let secondWork = StartupLibraryWork(
            id: secondWorkID.rawValue,
            title: secondDocument.title,
            availability: .local,
            workID: secondWorkID,
            remoteProgress: .idle
        )
        state.snapshotSyncLibraryWorks = [firstWork, secondWork]

        // A clean switch must not create a new local generation or intent.
        #expect(await state.openLibraryWork(firstWork))
        let cleanGeneration = try await application.open(workID: firstWorkID).generation
        #expect(await state.openLibraryWork(secondWork))
        let generationAfterCleanSwitch = try await application.open(workID: firstWorkID).generation
        #expect(generationAfterCleanSwitch == cleanGeneration)

        #expect(await state.openLibraryWork(firstWork))
        state.updateSelectedEpisodeContent("一覧へ戻る前に確定する本文")
        #expect(state.saveState == .unsaved)
        let generationBeforeDirtySwitch = try await application.open(workID: firstWorkID).generation

        #expect(await state.returnToSnapshotLibrary())
        guard case .documentSelection = state.startupState else {
            Issue.record("作品一覧へ戻る境界がdocumentSelectionを表示しませんでした")
            return
        }
        #expect(state.saveState == .saved)
        #expect(await state.openLibraryWork(secondWork))
        #expect(state.snapshotSyncV2ActiveWorkID == secondWorkID)
        #expect(await state.openLibraryWork(firstWork))

        let reopened = try await application.open(workID: firstWorkID)
        #expect(reopened.generation > generationBeforeDirtySwitch)
        #expect(state.document.chapters.first?.episodes.first?.content == "一覧へ戻る前に確定する本文")
    }

    @Test("Exportは明示時だけnovelpkgを作り通常identityを変えない")
    func explicitExportDoesNotChangeSessionIdentity() async throws {
        let state = try makeState()
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let session = state.documentSessionToken
        let destination = temporaryPackageURL("export")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await state.exportDocumentPackage(to: destination, expectedSession: session)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(state.documentSessionToken == session)
        #expect(state.userDefaults.string(forKey: "fuminiwa.v2.activeWorkID") == state.snapshotSyncV2ActiveWorkID?.rawValue.uuidString)
    }

    @Test("ImportのcreatedAtとopaque resourceはSQLite open後もcanonicalにExportされる")
    func importNormalizesCreatedAtAndPreservesResourcesAcrossReopenAndExport() async throws {
        let repository = NovelpkgRepository()
        let sourceURL = temporaryPackageURL("fractional-import")
        let exportedURL = temporaryPackageURL("fractional-export")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportedURL)
        }
        let sourceDocument = NovelDocument.newDocument(title: "小数秒作品")
        try await repository.save(sourceDocument, to: sourceURL)
        let resourceBytes = Data([0, 4, 8, 15, 16, 23, 42])
        try resourceBytes.write(to: sourceURL.appendingPathComponent("orphan.dat"))
        var manifest = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: sourceURL.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        manifest["createdAt"] = "2024-02-29T12:34:56.789Z"
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
            .write(to: sourceURL.appendingPathComponent("manifest.json"))

        let state = try makeState(
            repository: repository,
            account: TestAccount(accountID: "resource-fixture-account", accountFence: "resource-fixture-fence")
        )
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        #expect(await state.openExternalDocument(at: sourceURL))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedPortableCreatedAt = try #require(
            formatter.date(from: "2024-02-29T12:34:56.789Z")
        )
        let expectedCreatedAt = Date(timeIntervalSince1970: 1_709_210_096)
        #expect(state.snapshotSyncV2DocumentCreatedAt == expectedCreatedAt)
        #expect(state.snapshotSyncV2PortableCreatedAt == expectedPortableCreatedAt)
        let importedResources = state.snapshotSyncV2Resources
        #expect(importedResources.contains {
            $0.pathComponents == ["orphan.dat"] && $0.bytes == resourceBytes
        })
        let application = try #require(state.snapshotSyncV2Application)
        let workID = try #require(state.snapshotSyncV2ActiveWorkID)

        _ = try await application.checkpoint(
            workID: workID,
            document: state.document,
            reason: .close,
            documentCreatedAt: expectedCreatedAt,
            resources: nil
        )
        let factory = try #require(state.snapshotSyncV2Factory)
        let reopenedApplication = try await factory()
        let reopened = try await reopenedApplication.open(workID: workID)
        #expect(reopened.documentCreatedAt == expectedCreatedAt)
        let mirroredResources = try SyncV2PortableMetadata.resourcesForLocalMirror(
            importedResources,
            portableCreatedAt: expectedPortableCreatedAt
        )
        #expect(
            reopened.resources.sorted { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }
                == mirroredResources.sorted { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }
        )
        #expect(reopened.resources.first(where: { $0.pathComponents == ["orphan.dat"] })?.bytes == resourceBytes)

        let reopenedDocument = try #require(reopened.document)
        state.installV2Document(
            reopenedDocument,
            workID: reopened.workID,
            createdAt: reopened.documentCreatedAt,
            attachments: reopened.attachments,
            resources: reopened.resources
        )
        #expect(state.snapshotSyncV2PortableCreatedAt == expectedPortableCreatedAt)

        try await state.exportDocumentPackage(to: exportedURL)
        let exported = try await state.portableBridge.importExplicitPackage(from: exportedURL)
        #expect(exported.documentCreatedAt == expectedPortableCreatedAt)
        #expect(exported.resources == importedResources)
        #expect(exported.resources.first(where: { $0.pathComponents == ["orphan.dat"] })?.bytes == resourceBytes)
    }

    @Test("終了前保存はDocumentOperationGate内でlocal checkpointを完了する")
    func terminationSaveUsesLocalCheckpoint() async throws {
        let state = try makeState()
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        state.updateSelectedEpisodeContent("終了前の編集")

        #expect(await state.saveBeforeTermination())
        #expect(state.saveState == .saved)
        #expect(state.document.selectedEpisodeContentForTest == "終了前の編集")
    }

    private func makeState(
        repository: DocumentRepository = NovelpkgRepository(),
        account: TestAccount? = nil,
        checkpointOverride: SnapshotSyncV2CheckpointOverride? = nil
    ) throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.AppStateDocumentLifecycleTests.\(UUID().uuidString)"))
        let configuration = try TestRuntimeConfiguration(account: account)
        var dependencies = AppDependencies(
            repository: repository,
            userDefaults: defaults,
            defaultDocumentDirectoryName: "FUMINIWA-TestHost-\(UUID().uuidString)",
            snapshotSyncV2Factory: {
                try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
            }
        )
        dependencies.snapshotSyncV2CheckpointOverride = checkpointOverride
        return AppState(dependencies: dependencies)
    }

    private func temporaryPackageURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-\(label)-\(UUID().uuidString).novelpkg", isDirectory: true)
    }
}

private extension NovelDocument {
    var selectedEpisodeContentForTest: String? {
        chapters.first?.episodes.first?.content
    }
}
