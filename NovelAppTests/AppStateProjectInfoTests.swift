import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStateProjectInfoTests {
    @Test("作品情報のタイトルとあらすじ更新はモデルへ反映される")
    func projectInfoUpdatesDocumentMetadata() throws {
        let suiteName = "NovelWriterProjectInfo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let state = AppState(
            dependencies: AppDependencies(
                repository: ProjectInfoRepository(),
                userDefaults: defaults,
                fileManager: .default
            )
        )

        state.updateDocumentTitle("")
        state.updateDocumentSynopsis("作品のあらすじ")

        #expect(state.document.title.isEmpty)
        #expect(state.document.synopsis == "作品のあらすじ")
        #expect(state.saveState == .unsaved)
    }
}

private actor ProjectInfoRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
