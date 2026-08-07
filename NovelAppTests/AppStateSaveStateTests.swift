import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct AppStateSaveStateTests {
    @Test("明示保存はデバウンスを待たず現在revisionを保存する")
    func manualSaveFlushesCurrentRevision() async {
        let repository = ControllableRepository(shouldFail: false)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: makeUserDefaults(),
                fileManager: .default
            ),
            initialStartupState: .ready
        )

        state.updateSelectedEpisodeContent("今すぐ保存")

        #expect(await state.saveNow())
        #expect(state.saveState == .saved)
        #expect(await repository.saveCount == 1)
    }

    @Test("保存失敗は状態に反映され、次の保存で再試行できる")
    func saveFailureCanBeRetried() async {
        let repository = ControllableRepository(shouldFail: true)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: makeUserDefaults(),
                fileManager: .default
            ),
            initialStartupState: .ready
        )

        state.updateSelectedEpisodeContent("保存対象")
        #expect(state.saveState == .unsaved)

        let firstResult = await state.saveBeforeTermination()
        #expect(firstResult == false)
        #expect(state.saveState == .failed)

        await repository.setShouldFail(false)
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
}

private actor ControllableRepository: DocumentRepository {
    private var shouldFail: Bool
    private(set) var saveCount = 0

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {
        saveCount += 1
        if shouldFail {
            throw TestRepositoryError.saveFailed
        }
    }
}

private enum TestRepositoryError: Error {
    case saveFailed
}
