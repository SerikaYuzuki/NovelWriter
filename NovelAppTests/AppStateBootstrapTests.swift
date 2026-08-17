import Foundation
@testable import FUMINIWA
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct AppStateBootstrapTests {
    @Test("v2起動はSQLite checkpoint後にreadyになる")
    func bootstrapCreatesLocalWorkThroughV2() async throws {
        let state = try makeState()
        #expect(state.startupState == .loading)

        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()

        #expect(state.startupState == .ready)
        let activeWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        #expect(state.snapshotSyncV2Session?.workID == activeWorkID)
        #expect(activeWorkID.rawValue != state.document.id)
        #expect(state.userDefaults.string(forKey: "fuminiwa.v2.activeWorkID") == activeWorkID.rawValue.uuidString)
    }

    @Test("v2 runtime構築失敗はrecoveryで止まりfresh workbenchを出さない")
    func configurationFailureFailsClosed() async throws {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.AppStateBootstrapTests.failure.\(UUID().uuidString)"))
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                snapshotSyncV2Factory: {
                    throw SyncV2ApplicationError.invalidRuntimeMode
                }
            )
        )

        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory) == false)
        await state.bootstrap()

        guard case .recovery = state.startupState else {
            Issue.record("configure失敗後にrecoveryへ留まりませんでした")
            return
        }
        #expect(state.snapshotSyncV2Application == nil)
    }

    @Test("Finderからの取り込みは明示操作だけcodecを使いWorkIDへcheckpointする")
    func explicitImportUsesV2Session() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-bootstrap-\(UUID().uuidString).novelpkg", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = NovelDocument.newDocument(title: "取り込んだ作品")
        try await NovelpkgRepository().save(imported, to: source)
        let state = try makeState()
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()

        #expect(await state.openExternalDocument(at: source))
        #expect(state.document.title == imported.title)
        let activeWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        #expect(state.snapshotSyncV2Session?.workID == activeWorkID)
        #expect(activeWorkID.rawValue != imported.id)
        #expect(state.userDefaults.string(forKey: "fuminiwa.v2.activeWorkID") == activeWorkID.rawValue.uuidString)
    }

    private func makeState() throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "FUMINIWA.AppStateBootstrapTests.\(UUID().uuidString)"))
        let configuration = try TestRuntimeConfiguration(account: nil)
        return AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                defaultDocumentDirectoryName: "FUMINIWA-TestHost-\(UUID().uuidString)",
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            )
        )
    }
}
