import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStateProjectSectionTests {
    @Test("保存済みの企画選択は作品情報へ移行する")
    func planningSelectionMigratesToProjectInfo() throws {
        let suiteName = "NovelWriterProjectSection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("planning", forKey: "dev.serikayuzuki.NovelWriter.projectSection")

        let state = AppState(
            dependencies: AppDependencies(
                repository: ProjectSectionRepository(),
                userDefaults: defaults,
                fileManager: .default
            )
        )

        #expect(state.workspaceSelection.section == .projectInfo)
        #expect(defaults.string(forKey: "dev.serikayuzuki.NovelWriter.projectSection") == "projectInfo")
    }

    @Test("表示ショートカットは企画なしの7項目へ再割当する")
    func projectSectionShortcutsMatchRevisedOrder() {
        #expect(ProjectSection.allCases.map(\.rawValue) == [
            "projectInfo", "structure", "plot", "characters", "worldbuilding", "references", "settings"
        ])
        #expect(ProjectSection.allCases.map(\.keyboardShortcut.character) == ["1", "2", "3", "4", "5", "6", "7"])
    }
}

private actor ProjectSectionRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
