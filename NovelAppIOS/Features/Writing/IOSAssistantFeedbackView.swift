import SwiftUI

struct IOSAssistantFeedbackView: View {
    let store: IOSDocumentStore
    @State private var selection: UUID?
    var body: some View {
        IOSAssistantFeedbackOutline(store: store, selection: $selection, usesNavigationLinks: true)
    }
}

struct IOSAssistantFeedbackOutline: View {
    let store: IOSDocumentStore
    @Binding var selection: UUID?
    var usesNavigationLinks = false
    var body: some View {
        let session = store.currentDocumentSessionToken
        let account = store.snapshotSyncV2AccountScope
        AssistantFeedbackList(records: store.assistantFeedback, selection: $selection, usesNavigationLinks: usesNavigationLinks) { record in
            guard let session else { return false }
            return await store.deleteAssistantFeedback(record, session: session, account: account)
        }.id("\(String(describing: session))-\(account)")
    }
}
