import NovelCore
import NovelWorkspace
import SwiftUI

struct EpisodeRenameRequest {
    let episodeID: EpisodeID
    let chapterID: ChapterID
    let session: WorkspaceSessionToken
    let account: WorkspaceAccountScope
    var title: String

    @MainActor
    init(episode: Episode, chapterID: ChapterID, appState: AppState) {
        episodeID = episode.id
        self.chapterID = chapterID
        session = appState.workspaceModel.documentSessionToken
        account = appState.snapshotSyncV2AccountScopeToken
        title = episode.title
    }

    @MainActor
    func apply(to appState: AppState) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              appState.workspaceModel.documentSessionToken == session,
              appState.snapshotSyncV2AccountScopeToken == account else { return }
        appState.updateEpisodeTitle(normalizedTitle, for: episodeID, in: chapterID)
    }
}

/// Keep the dialog on the owning pane, including when the toolbar uses overflow.
struct EpisodeRenameDialog: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var request: EpisodeRenameRequest?

    func body(content: Content) -> some View {
        content.alert("話の名前を変更", isPresented: Binding(
            get: { request != nil },
            set: {
                if !$0 {
                    request = nil
                }
            }
        )) {
            TextField("話の名前", text: Binding(
                get: { request?.title ?? "" },
                set: { request?.title = $0 }
            ))
            Button("変更") {
                request?.apply(to: appState)
                request = nil
            }
            .keyboardShortcut(.defaultAction)
            .disabled(request?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            Button("キャンセル", role: .cancel) { request = nil }
        }
    }
}
