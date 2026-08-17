import NovelSyncV2
import SwiftUI

struct IOSLibraryView: View {
    let store: IOSDocumentStore
    let openDocument: (IOSPrivateDocumentID) -> Void
    let openCloudDocument: (WorkID) -> Void
    let makeNewDocument: () -> Void

    var body: some View {
        List {
            Section("この端末") {
                ForEach(store.libraryItems) { item in
                    Button {
                        openDocument(item.id)
                    } label: {
                        Label(item.title, systemImage: item.availability == .available ? "doc.text" : "exclamationmark.triangle")
                    }
                    .disabled(item.availability != .available)
                }
            }
            if !store.syncV2LibraryItems.isEmpty {
                Section("同期対象") {
                    ForEach(store.syncV2LibraryItems, id: \.workID) { item in
                        Button {
                            openCloudDocument(item.workID)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.title.isEmpty ? "名称未設定の作品" : item.title)
                                Text(item.remoteProgress.japaneseLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if item.conflict != nil {
                                    Text("競合を確認してください")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else if item.availability == .remoteOnly {
                                    Text("サーバーからこの端末へ取り込み")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button("新規作品", action: makeNewDocument)
                Button(".novelpkg を取り込む") { store.isImporterPresented = true }
            }
        }
        .navigationTitle("作品棚")
        .task { _ = await store.refreshLibrary() }
    }
}
