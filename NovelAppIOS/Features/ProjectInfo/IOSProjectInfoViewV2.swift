import SwiftUI

struct IOSProjectInfoView: View {
    let store: IOSDocumentStore
    var body: some View {
        Form {
            TextField("作品名", text: Binding(get: { store.document.title }, set: store.updateDocumentTitle))
            TextField("あらすじ", text: Binding(get: { store.document.synopsis }, set: store.updateDocumentSynopsis), axis: .vertical)
            LabeledContent("章", value: "\(store.document.chapters.count)")
            LabeledContent("話", value: "\(store.document.chapters.reduce(0) { $0 + $1.episodes.count })")
        }
        .navigationTitle("作品情報")
    }
}
