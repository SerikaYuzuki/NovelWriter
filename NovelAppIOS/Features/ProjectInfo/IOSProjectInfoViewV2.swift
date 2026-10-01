import NovelUI
import SwiftUI

struct IOSProjectInfoView: View {
    let store: IOSDocumentStore
    var body: some View {
        Form {
            Section {
                WorkInfoSummary(document: store.document)
                    .listRowBackground(FuminiwaColor.paper.color)
            }
            Section("編集") {
                TextField("作品名", text: Binding(get: { store.document.title }, set: store.updateDocumentTitle))
                TextField("あらすじ", text: Binding(get: { store.document.synopsis }, set: store.updateDocumentSynopsis), axis: .vertical)
            }
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .navigationTitle("作品情報")
    }
}
