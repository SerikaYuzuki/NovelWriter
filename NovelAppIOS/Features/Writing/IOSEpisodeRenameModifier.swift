import NovelCore
import SwiftUI

/// The draft owns the document/account captured when the menu action is chosen.
/// Renaming metadata does not replace the EditorKit content or editing token.
struct IOSEpisodeRenameModifier: ViewModifier {
    let store: IOSDocumentStore
    let chapterID: ChapterID
    let episode: Episode
    let titleMenu: Bool
    @State private var isPresented = false
    @State private var draftTitle = ""
    @State private var applyRename: ((String) -> Void)?

    func body(content: Content) -> some View {
        Group {
            if titleMenu {
                content.toolbar {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            renameButton
                        } label: {
                            HStack(spacing: 4) {
                                Text(episode.title.isEmpty ? "無題の話" : episode.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel("話の名前：\(episode.title)")
                        .accessibilityIdentifier("ios.editor.episodeTitle")
                        .contextMenu { renameButton }
                    }
                }
            } else {
                content.contextMenu { renameButton }
            }
        }
        .alert("話の名前を変更", isPresented: $isPresented) {
            TextField("話の名前", text: $draftTitle)
            Button("キャンセル", role: .cancel) { applyRename = nil }
            Button("変更") {
                applyRename?(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                applyRename = nil
            }
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var renameButton: some View {
        Button("話の名前を変更", systemImage: "pencil") {
            guard let session = store.currentDocumentSessionToken else { return }
            let accountScope = store.snapshotSyncV2AccountScope
            let targetChapterID = chapterID
            let targetEpisodeID = episode.id
            draftTitle = episode.title
            applyRename = { title in
                store.updateEpisodeTitle(
                    title, chapterID: targetChapterID, episodeID: targetEpisodeID,
                    expectedSession: session, expectedAccountScope: accountScope
                )
            }
            isPresented = true
        }
    }
}
