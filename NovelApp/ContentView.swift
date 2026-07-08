import EditorKit
import NovelCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var searchSelectionRequest: EditorSelectionRequest?

    var body: some View {
        Group {
            switch appState.mode {
            case .writing:
                WritingModeView(
                    searchSelectionRequest: $searchSelectionRequest,
                    onOpenCharacter: { characterID in
                        appState.selectCharacter(characterID)
                        appState.mode = .characters
                    },
                    onOpenPlotCard: { cardID in
                        appState.selectPlotCard(cardID)
                        appState.mode = .plot
                    }
                )
            case .characters:
                CharacterModeView { appearance in
                    appState.mode = .writing
                    appState.selectChapter(appearance.chapterID)
                    searchSelectionRequest = EditorSelectionRequest(range: appearance.range)
                }
            case .plot:
                PlotModeView { chapterID in
                    appState.mode = .writing
                    appState.selectChapter(chapterID)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("モード", selection: modeBinding) {
                    ForEach(AppMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            ToolbarItemGroup {
                Spacer()

                if appState.mode == .writing {
                    Button {
                        appState.addChapter()
                    } label: {
                        Label("章を追加", systemImage: "plus")
                    }

                    Button {
                        NotificationCenter.default.post(name: .toggleWritingInspector, object: nil)
                    } label: {
                        Label("インスペクタ", systemImage: "sidebar.right")
                    }
                }
            }
        }
    }

    private var modeBinding: Binding<AppMode> {
        Binding(
            get: { appState.mode },
            set: { appState.mode = $0 }
        )
    }
}

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.NovelWriter.toggleWritingInspector")
}

#Preview {
    ContentView()
        .environment(AppState(dependencies: AppDependencies()))
        .environment(EditorSettings())
}
