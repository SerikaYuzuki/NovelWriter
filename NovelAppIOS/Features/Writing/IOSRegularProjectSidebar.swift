import NovelCore
import SwiftUI

enum IOSRegularProjectSection: Hashable {
    case projectInfo
    case writing
    case plot
    case characters
    case worldbuilding
    case references
    case settings
}

struct IOSRegularProjectSidebar: View {
    let store: IOSDocumentStore
    @Binding var selection: IOSRegularProjectSection?

    var body: some View {
        List(selection: $selection) {
            Section("この作品") {
                Label("作品情報", systemImage: "doc.text.magnifyingglass")
                    .tag(IOSRegularProjectSection.projectInfo)
                    .accessibilityIdentifier("ios.ipad.project.info")

                Label("執筆", systemImage: "square.and.pencil")
                    .tag(IOSRegularProjectSection.writing)
                    .accessibilityIdentifier("ios.ipad.project.writing")

                Label("プロット", systemImage: "rectangle.stack")
                    .tag(IOSRegularProjectSection.plot)
                    .accessibilityIdentifier("ios.ipad.project.plot")

                Label("登場人物", systemImage: "person.2")
                    .tag(IOSRegularProjectSection.characters)
                    .accessibilityIdentifier("ios.ipad.project.characters")

                Label("世界観", systemImage: "globe.asia.australia")
                    .tag(IOSRegularProjectSection.worldbuilding)
                    .accessibilityIdentifier("ios.ipad.project.worldbuilding")

                Label("資料", systemImage: "paperclip")
                    .tag(IOSRegularProjectSection.references)
                    .accessibilityIdentifier("ios.ipad.project.references")
            }

            Section("アプリ") {
                Label("設定", systemImage: "gearshape")
                    .tag(IOSRegularProjectSection.settings)
                    .accessibilityIdentifier("ios.ipad.project.settings")
            }

            Section("共有") {
                Button {
                    editorIdentityBoundary.perform {
                        Task {
                            await store.requestExport()
                        }
                    }
                } label: {
                    Label("作品を書き出す…", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("現在の作業コピーから、共有用のnovelpkgファイルを作ります。")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.thinMaterial)
        .navigationTitle(displayTitle)
    }

    private var displayTitle: String {
        let title = store.document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "名称未設定の作品" : title
    }

    private var editorIdentityBoundary: IOSWritingEditorIdentityBoundary {
        IOSWritingEditorIdentityBoundary(store: store)
    }
}
