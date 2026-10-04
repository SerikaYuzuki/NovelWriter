import NovelWorkspace
import NovelWorkspaceUI
import SwiftUI

struct IOSEpisodeHistorySheet: View {
    let store: IOSDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingWholeWorkHistory = false

    var body: some View {
        NavigationStack {
            if let context = EpisodeHistoryContext(document: store.document, episodeID: store.selectedEpisodeID),
               let application = store.snapshotSyncV2Application, let workID = store.syncV2ActiveWorkID {
                EpisodeHistoryList(application: application, workID: workID, chapterID: context.chapterID,
                                   episodeID: context.episodeID, heading: context.heading, scope: store.workSearchScope,
                                   userDefaults: store.userDefaults, currentBody: { store.episodeHistoryCurrentBody },
                                   host: { store.episodeRestoreHost(episodeID: context.episodeID) }, wholeWorkHistory: { showingWholeWorkHistory = true })
                    .id(store.workSearchScope + context.episodeID.description)
                    .navigationTitle("この話の履歴")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            }
        }
        .sheet(isPresented: $showingWholeWorkHistory) {
            NavigationStack { IOSSnapshotHistoryView(store: store) }
        }
    }
}
