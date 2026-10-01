import NovelThumbnail
import NovelUI
import SwiftUI

struct MacThumbnailEditor: View {
    @Environment(AppState.self) private var appState
    let owner: ThumbnailOwner
    let title: String
    var color: Color?
    var body: some View {
        let session = appState.documentSessionToken
        let account = appState.snapshotSyncV2AccountScopeToken
        ThumbnailEditor(owner: owner, data: appState.thumbnailData(owner), title: title, color: color) { bytes in
            await appState.setThumbnail(bytes, owner: owner, session: session, account: account)
        }
        .id("\(owner.fileName)-\(session)-\(account)")
    }
}
