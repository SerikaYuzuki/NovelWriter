import NovelWorkspaceUI
import SwiftUI

/// Settings sceneとWorkbenchの設定sectionで同じ内容を提供する。
struct AppSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selection = SettingsTab.writing

    private enum SettingsTab: Hashable {
        case writing
        case assistant
        case account
    }

    var body: some View {
        TabView(selection: $selection) {
            EditorSettingsView()
                .tabItem { Label("執筆", systemImage: "textformat") }
                .tag(SettingsTab.writing)
            NavigationStack {
                AssistantSettingsView(defaults: appState.userDefaults,
                                      writingHost: appState.writingAssistantHost,
                                      mcpController: appState.writingMCPController)
            }
            .tabItem { Label("AI支援", systemImage: "sparkles") }
            .tag(SettingsTab.assistant)
            Form {
                DeviceLabelSettingsView(defaults: appState.userDefaults)
                AccountAccessView()
            }
            .formStyle(.grouped)
            .tabItem { Label("アカウント", systemImage: "person.crop.circle") }
            .tag(SettingsTab.account)
        }
    }
}
