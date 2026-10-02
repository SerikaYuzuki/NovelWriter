import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct AppStateProjectSectionTests {
    @Test("サイドバーの全行から画面が切り替わる（未回収バッジ付きプロットを含む）")
    func sidebarSelectionSwitchesEverySection() async {
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(repository: ProjectSectionRepository(), userDefaults: defaults),
                             initialStartupState: .ready)
        state.document.flags = [Flag(title: "未回収の伏線", note: "")]
        #expect(state.document.flags.count(where: { !$0.isResolved }) == 1)
        var transition: Task<Bool, Never>?
        let selection = ProjectSidebarView.selectionBinding(appState: state) { section in
            transition = Task { await state.selectProjectSectionAfterTransition(section) }
        }
        for section in ProjectSection.allCases {
            selection.wrappedValue = section
            #expect(await transition?.value == true)
            #expect(state.workspaceSelection.section == section)
            #expect(selection.wrappedValue == section)
        }
    }

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

    @Test("既存ショートカットを保ち感想・アドバイスを追加する")
    func projectSectionShortcutsMatchRevisedOrder() {
        #expect(ProjectSection.allCases.map { $0.rawValue } == [
            "projectInfo", "structure", "plot", "characters", "worldbuilding", "references", "feedback", "settings"
        ])
        #expect(ProjectSection.allCases.map { $0.keyboardShortcut.character } == ["1", "2", "3", "4", "5", "6", "8", "7"])
    }
}

private actor ProjectSectionRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
