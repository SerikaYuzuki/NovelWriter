import Foundation
@testable import FUMINIWA
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
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

    private func makeState(repository: DocumentRepository = NovelpkgRepository()) throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.AppStateDocumentLifecycleTests.\(UUID().uuidString)"))
        let configuration = try TestRuntimeConfiguration(account: nil)
        return AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                defaultDocumentDirectoryName: "FUMINIWA-TestHost-\(UUID().uuidString)",
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
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
