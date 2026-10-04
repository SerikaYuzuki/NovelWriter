import NovelThumbnail
import NovelUI
import NovelWorkspace
import SwiftUI

struct IOSProjectInfoView: View {
    @Environment(WorkspaceModel.self) private var workspace
    let store: IOSDocumentStore
    var body: some View {
        Form {
            Section {
                IOSThumbnailEditor(store: store, owner: ThumbnailOwner(.work, workspace.document.id), title: workspace.document.title)
                WorkInfoSummary(document: workspace.document, showsCover: false)
                    .listRowBackground(FuminiwaColor.paper.color)
            }
            Section("編集") {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("作品タイトル").font(.headline)
                    TextField("作品タイトル", text: Binding(get: { workspace.document.title }, set: store.updateDocumentTitle))
                }
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("あらすじ").font(.headline)
                    TextField("あらすじ", text: Binding(get: { workspace.document.synopsis }, set: store.updateDocumentSynopsis), axis: .vertical)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .navigationTitle("作品情報")
    }
}
