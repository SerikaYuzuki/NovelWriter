import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct AppStateProjectSectionTests {
    @Test("保存済みの企画選択は作品情報へ移行する")
    func planningSelectionMigratesToProjectInfo() throws {
        let suiteName = "FUMINIWAProjectSection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("planning", forKey: AppPreferenceKey.projectSection)

        let state = AppState(
            dependencies: AppDependencies(
                repository: ProjectSectionRepository(),
                userDefaults: defaults,
                fileManager: .default
            ),
            initialStartupState: .ready
        )

        #expect(state.workspaceSelection.section == .projectInfo)
        #expect(defaults.string(forKey: AppPreferenceKey.projectSection) == "projectInfo")
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
