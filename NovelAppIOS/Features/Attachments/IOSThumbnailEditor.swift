import NovelThumbnail
import NovelUI
import SwiftUI

struct IOSThumbnailEditor: View {
    let store: IOSDocumentStore
    let owner: ThumbnailOwner
    let title: String
    var color: Color?
    var body: some View {
        let session = store.currentDocumentSessionToken
        let account = store.snapshotSyncV2AccountScope
        ThumbnailEditor(owner: owner, data: store.thumbnailData(owner), title: title, color: color) { bytes in
            guard let session else { return false }
            return await store.setThumbnail(bytes, owner: owner, session: session, account: account)
        }
        .id("\(owner.fileName)-\(String(describing: session))-\(account)")
    }
}
