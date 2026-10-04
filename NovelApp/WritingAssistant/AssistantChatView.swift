import Foundation
import NovelCore
import NovelUI
import NovelWorkspaceUI
import NovelWritingSupport
import SwiftUI

struct AssistantChatView: View {
    let host: WritingAssistantHost
    let defaults: UserDefaults
    let chapters: [Chapter]
    let currentEpisodeID: EpisodeID?
    @Binding var referenceScope: AssistantScope
    @State private var entries: [WritingEnvelope] = []
    @State private var conversationId: UUID?
    @State private var input = ""
    @State private var scope = ChatEditScope.advice
    @State private var notice: String?
    @State private var syncNotice: String?
    @State private var showingScope = false
    @State private var renameTitle = ""
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var localRevision = 0
    @State private var showingPrompts = false
    @State private var showingEdits = false

    private var conversations: [WritingEnvelope] {
        _ = localRevision
        let hidden = defaults.stringArray(forKey: "assistant.hiddenConversations.\(host.workID)") ?? []
        return WritingConversation.displayed(entries).filter { !hidden.contains($0.id.uuidString) }
    }

    private var requestKey: AssistantRequestKey {
        host.requestKey(purpose: .advice, conversation: conversationId)
    }

    private var inFlight: Bool {
        host.requestCenter.statuses[requestKey]?.inFlight == true
    }

    private var latestRequest: WritingEnvelope? {
        AssistantRequestRecord.latest(entries).filter {
            (try? $0.record.decoded(AssistantRequestRecord.self).conversationId) == conversationId
        }.max { $0.record.createdAt < $1.record.createdAt }
    }

    private func title(_ item: WritingEnvelope) -> String {
        (try? item.record.decoded(WritingConversation.self).title) ?? "会話の記録"
    }

    private var messages: [WritingMessage] {
        conversationId.map { WritingConversation.messages(entries, conversation: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if !conversations.isEmpty {
                    Picker("会話", selection: Binding(get: { conversationId }, set: selectConversation)) {
                        Text("新しい会話").tag(UUID?.none)
                        if let conversationId, !conversations.contains(where: { $0.id == conversationId }) {
                            Text("新しい会話").tag(Optional(conversationId))
                        }
                        ForEach(conversations) { item in
                            Text(title(item)).tag(Optional(item.id))
                        }
                    }.labelsHidden()
                }
                Button("新しい会話", systemImage: "square.and.pencil") { selectConversation(nil) }
                    .labelStyle(.iconOnly).help("新しい会話")
                Button("変更履歴", systemImage: "clock.arrow.circlepath") { showingEdits = true }.labelStyle(.iconOnly)
                Button("指示", systemImage: "slider.horizontal.3") { showingPrompts = true }.labelStyle(.iconOnly)
            }
            if let conversationId {
                Menu("会話の操作", systemImage: "ellipsis") {
                    Button("名前を変更…") {
                        renameTitle = conversations.first(where: { $0.id == conversationId }).map(title) ?? ""; showingRename = true
                    }
                    Button("削除…", role: .destructive) { showingDelete = true }
                }
            }
            DisclosureGroup("送る範囲：\(referenceScope.summary(chapters: chapters, currentID: currentEpisodeID))", isExpanded: $showingScope) {
                AssistantScopeSelector(chapters: chapters, currentID: currentEpisodeID, scope: $referenceScope)
            }.disabled(inFlight)
            Text("人物・プロット・設定と、この会話の履歴も参照します。")
                .font(.caption2).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "あなた" : "AI").font(.caption).foregroundStyle(.secondary)
                                if message.role == "user", let id = message.requestId,
                                   let record = entries.first(where: { $0.record.kind == "request" && $0.record.key == id.uuidString.lowercased() }),
                                   let metadata = try? record.record.decoded(AssistantRequestRecord.self) {
                                    Text(metadata.caption).font(.caption2).foregroundStyle(.secondary)
                                }
                                AssistantMarkdownView(source: message.text).textSelection(.enabled)
                                if message.role == "assistant", let id = message.requestId,
                                   entries.contains(where: { $0.record.kind == "edit" && $0.record.key == id.uuidString.lowercased() }) {
                                    Button("この依頼の編集を取り消す") { Task { await undo(id) } }
                                        .font(.caption)
                                }
                            }
                            .padding(message.role == "user" ? Spacing.medium : 0)
                            .background(message.role == "user" ? FuminiwaColor.accentMuted.color : Color.clear,
                                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .padding(message.role == "user" ? .leading : .trailing, Spacing.large)
                            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                            .id(index)
                        }
                    }
                }.onChange(of: messages.count) {
                    _, count in if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let syncNotice {
                Text(syncNotice).font(.caption2).foregroundStyle(.secondary)
            }
            AssistantRequestStatusView(host: host, key: requestKey, defaults: defaults, rebuild: rebuildChat)
            if !inFlight, let latestRequest, let state = try? latestRequest.record.decoded(AssistantRequestRecord.self),
               ["interrupted", "failed", "cancelled"].contains(state.state) || (state.state == "sent" && host.interrupted(latestRequest.record, defaults: defaults)) {
                Label("中断した依頼があります", systemImage: "exclamationmark.triangle").font(.caption)
                Button("再送", action: retry)
            }
            if let latestRequest, let state = try? latestRequest.record.decoded(AssistantRequestRecord.self), state.state == "pending" {
                Text(state.detail ?? "未反映の変更案があります。変更履歴から確認できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("相談・生成・修正を依頼", text: $input, axis: .vertical)
                .lineLimit(2 ... 10).textFieldStyle(.roundedBorder).onSubmit(send)
            HStack {
                Menu {
                    Picker("編集許可", selection: $scope) {
                        ForEach(ChatEditScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label(scope.rawValue, systemImage: "pencil.tip.crop.circle") }.disabled(inFlight)
                Spacer()
                Button("送信", action: send).buttonStyle(.borderedProminent)
                    .disabled(inFlight || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("会話の名前", isPresented: $showingRename) {
            TextField("会話の名前", text: $renameTitle)
            Button("保存") {
                if let conversationId {
                    Task { @MainActor in
                        do {
                            guard let root = conversations.first(where: { $0.id == conversationId }) else { return }
                            let old = try root.record.decoded(WritingConversation.self)
                            let key = conversationId.uuidString.lowercased()
                            let parent = entries.last(where: { $0.record.kind == "conversation" && $0.record.key == key })?.id ?? conversationId
                            try await host.append(WritingRecord(workId: host.workID, kind: "conversation", key: key, parentId: parent,
                                                                payload: WritingRecord.payload(WritingConversation(title: renameTitle, documentId: old.documentId, readConsent: old.readConsent))))
                            host.requestCenter.changed(); await reload()
                        } catch { notice = error.localizedDescription }
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("この会話をこの端末で非表示にしますか？", isPresented: $showingDelete) {
            Button("削除", role: .destructive) {
                if let conversationId {
                    let key = "assistant.hiddenConversations.\(host.workID)"
                    var hidden = defaults.stringArray(forKey: key) ?? []; hidden.append(conversationId.uuidString)
                    defaults.set(hidden, forKey: key); selectConversation(nil); localRevision += 1
                }
            }
        }
        .sheet(isPresented: $showingEdits) {
            NavigationStack {
                WritingEditHistoryView(host: host)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showingEdits = false } } }
            }.frame(minWidth: 350, minHeight: 440)
        }
        .sheet(isPresented: $showingPrompts) {
            NavigationStack {
                WritingPromptsView(host: host, defaults: defaults)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showingPrompts = false } } }
            }.frame(minWidth: 350, minHeight: 460)
        }
        .modifier(WritingSyncVisibility(host: host))
        .task(id: host.contextID) {
            await reload()
            if conversationId == nil, input.isEmpty, !inFlight {
                let selectionKey = host.requestKey(purpose: .advice)
                let selected = host.requestCenter.conversationSelections[selectionKey]
                conversationId = selected.flatMap { id in
                    conversations.contains(where: { $0.id == id }) || host.requestCenter.statuses[host.requestKey(purpose: .advice, conversation: id)] != nil ? id : nil
                } ?? conversations.last?.id
                scope = ChatEditScope(rawValue: host.requestCenter.conversationPermissions[requestKey] ?? "") ?? .advice
            }
        }
        .onChange(of: host.requestCenter.revision) { _, _ in Task { await reload() } }
        .onChange(of: scope) { _, value in
            if conversationId != nil {
                host.requestCenter.conversationPermissions[requestKey] = value.rawValue
            }
        }
        .onChange(of: host.syncScheduler?.revision) { _, _ in
            Task { await reload() }
        }
        .onChange(of: host.syncScheduler?.failed, initial: true) { _, failed in
            syncNotice = failed == true ? "会話はこの端末に保存済み。同期は接続できると再試行します。" : nil
        }

        .onChange(of: host.contextID) { _, _ in conversationId = nil; entries = []; scope = .advice }
    }

    private func reload() async {
        let context = host.contextID
        do {
            let loaded = try await host.recoverInterruptedRequests(host.records(false), defaults: defaults)
            guard host.contextID == context else { return }
            entries = loaded
        } catch { notice = error.localizedDescription }
    }

    private func selectConversation(_ id: UUID?) {
        conversationId = id; scope = .advice
        host.requestCenter.conversationSelections[host.requestKey(purpose: .advice)] = id
        if id != nil {
            host.requestCenter.conversationPermissions[requestKey] = ChatEditScope.advice.rawValue
        }
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inFlight, !question.isEmpty else { return }
        do {
            let id = conversationId ?? UUID(), isNew = conversationId == nil
            if let selected = conversationId {
                _ = try WritingConversation.recordForSending(selectedID: selected, conversations: conversations, capture: host.capture())
            }
            if try host.sendChat(question: question, conversation: id, isNew: isNew, history: messages,
                                 scope: scope, reference: referenceScope, defaults: defaults) {
                conversationId = id; input = ""; notice = nil
                host.requestCenter.conversationSelections[host.requestKey(purpose: .advice)] = id
                host.requestCenter.conversationPermissions[requestKey] = scope.rawValue
            }
        } catch { notice = error.localizedDescription }
    }

    private func retry() {
        Task { @MainActor in
            do {
                let entries = try await host.records(false)
                let request = AssistantRequestRecord.latest(entries).filter {
                    (try? $0.record.decoded(AssistantRequestRecord.self).conversationId) == conversationId
                }.max { $0.record.createdAt < $1.record.createdAt }
                if let request {
                    if try await !host.retry(request.record, entries: entries, defaults: defaults) {
                        try await rebuildChat()
                    }
                }
            } catch { notice = error.localizedDescription }
        }
    }

    private func rebuildChat() async throws {
        guard let conversationId, !inFlight else { return }
        let saved = try await host.records(false)
        _ = try WritingConversation.recordForSending(selectedID: conversationId, conversations: WritingConversation.displayed(saved), capture: host.capture())
        let history = WritingConversation.messages(saved, conversation: conversationId)
        guard let lastUser = history.lastIndex(where: { $0.role == "user" }) else { throw WritingError.invalidRecord }
        _ = try host.sendChat(question: history[lastUser].text, conversation: conversationId, isNew: false,
                              history: Array(history.prefix(lastUser)), scope: scope, reference: referenceScope, defaults: defaults, reusingQuestion: true)
    }

    private func undo(_ id: UUID) async {
        do { try await host.undo(id); notice = "この依頼による変更を取り消しました。" }
        catch { notice = error.localizedDescription }
    }
}
