import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStateSaveStateTests {
    @Test("保存失敗は状態に反映され、次の保存で再試行できる")
    func saveFailureCanBeRetried() async {
        let repository = ControllableRepository(shouldFail: true)
        let state = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: makeUserDefaults(),
                fileManager: .default
            )
        )

        state.updateSelectedChapterContent("保存対象")
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
        let suiteName = "NovelWriterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor ControllableRepository: DocumentRepository {
    private var shouldFail: Bool

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
        if shouldFail {
            throw TestRepositoryError.saveFailed
        }
    }
}

private enum TestRepositoryError: Error {
    case saveFailed
}
