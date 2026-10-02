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
                    .accessibilityIdentifier("ios.ipad.project.info")
                    .tag(IOSRegularProjectSection.projectInfo)

                ProjectSectionStyle.writing.label
                    .accessibilityIdentifier("ios.ipad.project.writing")
                    .tag(IOSRegularProjectSection.writing)

                ProjectSectionStyle.plot.label
                    .badge(store.document.flags.count(where: { !$0.isResolved }))
                    .accessibilityIdentifier("ios.ipad.project.plot")
                    .tag(IOSRegularProjectSection.plot)

                ProjectSectionStyle.characters.label
                    .accessibilityIdentifier("ios.ipad.project.characters")
                    .tag(IOSRegularProjectSection.characters)

                ProjectSectionStyle.worldbuilding.label
                    .accessibilityIdentifier("ios.ipad.project.worldbuilding")
                    .tag(IOSRegularProjectSection.worldbuilding)

                ProjectSectionStyle.feedback.label
                    .accessibilityIdentifier("ios.ipad.project.feedback")
                    .tag(IOSRegularProjectSection.feedback)

                ProjectSectionStyle.references.label
                    .accessibilityIdentifier("ios.ipad.project.references")
                    .tag(IOSRegularProjectSection.references)
            }

            Section("アプリ") {
                ProjectSectionStyle.settings.label
                    .accessibilityIdentifier("ios.ipad.project.settings")
                    .tag(IOSRegularProjectSection.settings)
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
                Button {
                    editorIdentityBoundary.perform { Task { await store.requestExport(readable: true) } }
                } label: {
                    Label("本文と資料を書き出す（ZIP）", systemImage: "square.and.arrow.up")
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
