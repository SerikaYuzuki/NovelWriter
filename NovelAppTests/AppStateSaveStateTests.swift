import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct AppStateSaveStateTests {
    @Test("明示保存はデバウンスを待たず現在revisionを保存する")
    func manualSaveFlushesCurrentRevision() async throws {
        let state = try makeState()
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()

        state.updateSelectedEpisodeContent("今すぐ保存")

        #expect(await state.saveNow())
        #expect(state.saveState == .saved)
        #expect(state.snapshotSyncV2Session?.workID == state.snapshotSyncV2ActiveWorkID)
        #expect(state.snapshotSyncV2Session?.workID.rawValue != state.document.id)
    }

    @Test("保存失敗は状態に反映され、次の保存で再試行できる")
    func saveFailureCanBeRetried() async throws {
        let state = try makeState()

        state.updateSelectedEpisodeContent("保存対象")
        #expect(state.saveState == .unsaved)

        let firstResult = await state.saveBeforeTermination()
        #expect(firstResult == false)
        #expect(state.saveState == .failed)

        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let retryResult = await state.saveBeforeTermination()
        #expect(retryResult == true)
        #expect(state.saveState == .saved)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "FUMINIWASaveStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeState() throws -> AppState {
        let configuration = try TestRuntimeConfiguration(account: nil)
        return AppState(
            dependencies: AppDependencies(
                userDefaults: makeUserDefaults(),
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            ),
            initialStartupState: .ready
        )
    }
}
