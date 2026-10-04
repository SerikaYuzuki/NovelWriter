import NovelWorkspaceUI
import SwiftUI

struct AssistantFeedbackList: View {
    let records: [AssistantFeedback]
    @Binding var selection: UUID?
    var usesNavigationLinks = false
    var writingHost: WritingAssistantHost?
    let delete: (AssistantFeedback) async -> Bool
    @State private var pendingDeletion: AssistantFeedback?
    @State private var deletionFailed = false
    @State private var isDeleting = false
    @State private var recorded: [AssistantFeedback] = []
    @State private var hidden: [String] = []
    private var displayed: [AssistantFeedback] {
        (records + recorded.filter { item in !records.contains(where: { $0.id == item.id }) })
            .filter { !hidden.contains($0.id.uuidString) }.sorted { $0.createdAt > $1.createdAt }
    }

    private var hiddenKey: String {
        "assistant.hiddenFeedback.\(writingHost?.workID.uuidString ?? "local")"
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(displayed) { record in
                Group {
                    if usesNavigationLinks {
                        NavigationLink {
                            AssistantFeedbackDetail(record: displayed.first { $0.id == record.id })
                                .modifier(WritingSyncVisibility(host: writingHost))
                        } label: {
                            row(record)
                        }
                    } else {
                        row(record)
                    }
                }
                .contextMenu {
                    Button("削除…", systemImage: "trash", role: .destructive) { pendingDeletion = record }
                }
                .disabled(isDeleting)
                .tag(record.id)
            }
        }
        .overlay {
            if displayed.isEmpty {
                ContentUnavailableView("感想はまだありません", systemImage: "text.bubble",
                                       description: Text("執筆画面のAI支援で「感想」を送信すると、回答をここに保存します。"))
            }
        }
        .navigationTitle("感想")
        .task(id: writingHost?.contextID) { await loadRecorded() }
        .onChange(of: writingHost?.requestCenter.revision) { _, _ in Task { await loadRecorded() } }
        .onChange(of: writingHost?.syncScheduler?.revision) { _, _ in Task { await loadRecorded() } }
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
                    let saved: Bool
                    if recorded.contains(where: { $0.id == record.id }), !records.contains(where: { $0.id == record.id }) {
                        hidden.append(record.id.uuidString); writingHost?.defaults.set(hidden, forKey: hiddenKey); saved = true
                    } else {
                        saved = await delete(record)
                    }
                    if saved {
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
            Text(recorded.contains(where: { $0.id == record.id }) ? "この回答をこの端末で非表示にします。" : "\(record.title)（\(record.createdAt.formatted(date: .numeric, time: .standard))）を削除します。作品を同期している端末にも反映されます。")
        }
        .alert("削除できませんでした", isPresented: $deletionFailed) {
            Button("閉じる", role: .cancel) {}
        } message: { Text("作品と入力状態を確認して、もう一度お試しください。") }
    }

    private func loadRecorded() async {
        hidden = writingHost?.defaults.stringArray(forKey: hiddenKey) ?? []
        guard let writingHost else { recorded = []; return }
        if let entries = try? await writingHost.records(false), !Task.isCancelled {
            recorded = writingHost.recordedFeedback(entries)
        }
    }

    private func row(_ record: AssistantFeedback) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title).lineLimit(2)
            Text(record.createdAt.formatted(date: .numeric, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("assistant.feedback.\(record.id)")
    }
}

#if os(macOS)
struct MacAssistantFeedbackOutline: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: UUID?
    var body: some View {
        let session = appState.documentSessionToken
        let account = appState.snapshotSyncV2AccountScopeToken
        AssistantFeedbackList(records: appState.assistantFeedback, selection: $selection, writingHost: appState.writingAssistantHost) { record in
            await appState.deleteAssistantFeedback(record, session: session, account: account)
        }.id("\(session)-\(account)")
            .workbenchGlassOutlineStyle()
            .modifier(WritingSyncVisibility(host: appState.writingAssistantHost))
    }
}
#endif
