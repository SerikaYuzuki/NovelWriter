import SwiftUI

struct AssistantFeedbackList: View {
    let records: [AssistantFeedback]
    @Binding var selection: UUID?
    var usesNavigationLinks = false
    let delete: (AssistantFeedback) async -> Bool
    @State private var pendingDeletion: AssistantFeedback?
    @State private var deletionFailed = false
    @State private var isDeleting = false

    var body: some View {
        List(selection: $selection) {
            ForEach(records) { record in
                Group {
                    if usesNavigationLinks {
                        NavigationLink { AssistantFeedbackDetail(record: records.first { $0.id == record.id }) } label: {
                            row(record)
                        }
                    } else {
                        row(record).tag(record.id)
                    }
                }
                .contextMenu {
                    Button("削除…", systemImage: "trash", role: .destructive) { pendingDeletion = record }
                }
                .disabled(isDeleting)
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("感想・アドバイスはまだありません", systemImage: "text.bubble",
                                       description: Text("執筆画面のAI支援から送信すると、回答をここに保存します。"))
            }
        }
        .navigationTitle("感想・アドバイス")
        .confirmationDialog("この回答を削除しますか？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: {
                if !$0 {
                    pendingDeletion = nil
                }
            }
        ), presenting: pendingDeletion) { record in
            Button("削除", role: .destructive) {
                Task {
                    isDeleting = true
                    defer { isDeleting = false }
                    if await delete(record) {
                        if selection == record.id {
                            selection = nil
                        }
                    } else {
                        deletionFailed = true
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { record in
            Text("\(record.title)（\(record.createdAt.formatted(date: .numeric, time: .standard))）を削除します。作品を同期している端末にも反映されます。")
        }
        .alert("削除できませんでした", isPresented: $deletionFailed) {
            Button("閉じる", role: .cancel) {}
        } message: { Text("作品と入力状態を確認して、もう一度お試しください。") }
    }

    private func row(_ record: AssistantFeedback) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title).lineLimit(2)
            Text(record.createdAt.formatted(date: .numeric, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("assistant.feedback.\(record.id)")
    }
}

struct AssistantFeedbackDetail: View {
    let record: AssistantFeedback?
    var body: some View {
        if let record {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(record.title).font(.title2.bold())
                    Text(record.createdAt.formatted(date: .complete, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    AssistantMarkdownView(source: record.markdown)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.textSelection(.enabled)
                .navigationTitle(record.purpose.rawValue)
        } else {
            ContentUnavailableView("回答を選択してください", systemImage: "text.bubble",
                                   description: Text("左の一覧から、保存した感想・アドバイスを読めます。"))
        }
    }
}

#if os(macOS)
struct MacAssistantFeedbackOutline: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: UUID?
    var body: some View {
        let session = appState.documentSessionToken
        let account = appState.snapshotSyncV2AccountScopeToken
        AssistantFeedbackList(records: appState.assistantFeedback, selection: $selection) { record in
            await appState.deleteAssistantFeedback(record, session: session, account: account)
        }.id("\(session)-\(account)")
            .workbenchGlassOutlineStyle()
    }
}
#endif
