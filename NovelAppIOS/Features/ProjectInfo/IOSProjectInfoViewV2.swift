import NovelThumbnail
import NovelUI
import SwiftUI

struct IOSProjectInfoView: View {
    let store: IOSDocumentStore
    var body: some View {
        Form {
            Section {
                IOSThumbnailEditor(store: store, owner: ThumbnailOwner(.work, store.document.id), title: store.document.title)
                WorkInfoSummary(document: store.document, showsCover: false)
                    .listRowBackground(FuminiwaColor.paper.color)
            }
            Section("編集") {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("作品タイトル").font(.headline)
                    TextField("作品タイトル", text: Binding(get: { store.document.title }, set: store.updateDocumentTitle))
                }
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("あらすじ").font(.headline)
                    TextField("あらすじ", text: Binding(get: { store.document.synopsis }, set: store.updateDocumentSynopsis), axis: .vertical)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .navigationTitle("作品情報")
    }
}
