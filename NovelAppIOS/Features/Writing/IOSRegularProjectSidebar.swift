import NovelCore
import NovelUI
import SwiftUI

enum IOSRegularProjectSection: Hashable {
    case projectInfo
    case writing
    case plot
    case characters
    case worldbuilding
    case references
    case feedback
    case settings
}

struct IOSRegularProjectSidebar: View {
    let store: IOSDocumentStore
    @Binding var selection: IOSRegularProjectSection?

    var body: some View {
        List(selection: $selection) {
            Section("この作品") {
                ProjectSectionStyle.projectInfo.label
                    .tag(IOSRegularProjectSection.projectInfo)
                    .accessibilityIdentifier("ios.ipad.project.info")

                ProjectSectionStyle.writing.label
                    .tag(IOSRegularProjectSection.writing)
                    .accessibilityIdentifier("ios.ipad.project.writing")

                ProjectSectionStyle.plot.label
                    .badge(store.document.flags.count(where: { !$0.isResolved }))
                    .tag(IOSRegularProjectSection.plot)
                    .accessibilityIdentifier("ios.ipad.project.plot")

                ProjectSectionStyle.characters.label
                    .tag(IOSRegularProjectSection.characters)
                    .accessibilityIdentifier("ios.ipad.project.characters")

                ProjectSectionStyle.worldbuilding.label
                    .tag(IOSRegularProjectSection.worldbuilding)
                    .accessibilityIdentifier("ios.ipad.project.worldbuilding")

                ProjectSectionStyle.feedback.label
                    .tag(IOSRegularProjectSection.feedback)
                    .accessibilityIdentifier("ios.ipad.project.feedback")

                ProjectSectionStyle.references.label
                    .tag(IOSRegularProjectSection.references)
                    .accessibilityIdentifier("ios.ipad.project.references")
            }

            Section("アプリ") {
                ProjectSectionStyle.settings.label
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
                Button("本文と資料を書き出す（ZIP）") {
                    editorIdentityBoundary.perform { Task { await store.requestExport(readable: true) } }
                }
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
