import Foundation
import NovelCore
import NovelWritingSupport
import SwiftUI

private struct WritingConversation: Codable {
    let title: String
    let documentId: UUID
    let readConsent: Bool
}

private struct WritingTurnState: Codable {
    let state: String
    let effectivePrompt: String
    let conversationId: UUID
    let detail: String
}

private enum ChatEditScope: String, CaseIterable, Identifiable {
    case advice = "相談だけ", continuation = "選択中の話に追記", episode = "選択中の話を編集"
    case plots = "プロット", characters = "登場人物", materials = "設定・資料", whole = "作品全体"
    var id: String {
        rawValue
    }

    func grant(_ capture: WritingCapture) throws -> WritingGrant {
        switch self {
        case .advice: return .readOnly
        case .continuation, .episode:
            guard let path = capture.episodePath else { throw AssistantError.emptyContent }
            return WritingGrant(paths: [path + ["content"]], appendOnly: self == .continuation)
        case .plots: return WritingGrant(paths: [["plotCards"]])
        case .characters: return WritingGrant(paths: [["characters"]])
        case .materials: return WritingGrant(paths: [["characters"], ["plotCards"], ["flags"], ["worldNotes"]])
        case .whole: return .wholeWork
        }
    }
}

struct AssistantChatView: View {
    let host: WritingAssistantHost
    let defaults: UserDefaults
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [WritingEnvelope] = []
    @State private var conversationId: UUID?
    @State private var input = ""
    @State private var scope = ChatEditScope.advice
    @State private var notice: String?
    @State private var syncNotice: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var requestId: UUID?
    @State private var showingPrompts = false
    @State private var showingEdits = false
    @State private var creating = false

    private var conversations: [WritingEnvelope] {
        entries.filter { $0.record.kind == "conversation" }
    }

    private var messages: [WritingMessage] {
        entries.filter { $0.record.kind == "message" && $0.record.key == conversationId?.uuidString.lowercased() }
            .compactMap { try? $0.record.decoded(WritingMessage.self) }
    }

    private var consented: Bool {
        guard let capture = try? host.capture(), let item = conversations.first(where: { $0.id == conversationId }),
              let conversation = try? item.record.decoded(WritingConversation.self) else { return false }
        return conversation.readConsent && conversation.documentId == capture.document.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if !conversations.isEmpty {
                    Picker("会話", selection: $conversationId) {
                        ForEach(conversations) { item in
                            Text((try? item.record.decoded(WritingConversation.self).title) ?? "会話の記録").tag(Optional(item.id))
                        }
                    }.labelsHidden().disabled(requestTask != nil)
                }
                Button("新しい会話") { conversationId = nil }.disabled(requestTask != nil)
                Button("変更履歴", systemImage: "clock.arrow.circlepath") { showingEdits = true }.labelStyle(.iconOnly)
                Button("指示", systemImage: "slider.horizontal.3") { showingPrompts = true }.labelStyle(.iconOnly)
            }
            if !consented {
                Text("この会話では、現在の作品の本文・人物・プロット・設定をAIが参照します。送信はあなたが依頼したときだけです。")
                    .font(.callout)
                Text("送信先：\(AssistantPreferences(defaults: defaults).endpoint)").font(.caption).textSelection(.enabled)
                Button("この作品の参照を許可して会話を始める") { Task { await createConversation() } }
                    .disabled(creating)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "あなた" : "AI").font(.caption).foregroundStyle(.secondary)
                                AssistantMarkdownView(source: message.text).textSelection(.enabled)
                                if message.role == "assistant", let id = message.requestId,
                                   entries.contains(where: { $0.record.kind == "edit" && $0.record.key == id.uuidString.lowercased() }) {
                                    Button("この依頼の編集を取り消す") { Task { await undo(id) } }
                                        .font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(index)
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
            if requestTask == nil, hasUnfinishedRequest {
                Text("未完了の依頼があります。中断・別端末の処理中の可能性があります。自動再送はしません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("今回の編集許可", selection: $scope) {
                ForEach(ChatEditScope.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(requestTask != nil || !consented)
            TextField("相談・生成・修正を依頼", text: $input, axis: .vertical)
                .lineLimit(2 ... 6).textFieldStyle(.roundedBorder).disabled(!consented)
            HStack {
                Text("編集許可はこの依頼だけに使います。").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if requestTask != nil {
                    ProgressView().controlSize(.small)
                    Button("中止") { requestTask?.cancel() }
                } else {
                    Button("送信", action: send).buttonStyle(.borderedProminent)
                        .disabled(!consented || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingEdits) {
            NavigationStack {
                WritingEditHistoryView(host: host)
                    .toolbar { Button("閉じる") { showingEdits = false } }
            }.frame(minWidth: 350, minHeight: 440)
        }
        .sheet(isPresented: $showingPrompts) {
            NavigationStack {
                WritingPromptsView(host: host, defaults: defaults)
                    .toolbar { Button("閉じる") { showingPrompts = false } }
            }.frame(minWidth: 350, minHeight: 460)
        }
        .task(id: host.contextID) {
            await reload()
            if conversationId == nil {
                conversationId = conversations.last?.id
            }
            while !Task.isCancelled {
                if scenePhase == .active {
                    do { try await host.synchronize(); syncNotice = nil; await reload() }
                    catch {
                        if !Task.isCancelled {
                            syncNotice = "会話はこの端末に保存済み。同期は接続できると再試行します。"
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onChange(of: host.contextID) { _, _ in requestTask?.cancel(); conversationId = nil; entries = []; scope = .advice }
        .onDisappear { requestTask?.cancel() }
    }

    private var hasUnfinishedRequest: Bool {
        let requests = entries.filter { $0.record.kind == "request" }
        let latest = Dictionary(grouping: requests, by: { $0.record.key }).values.compactMap(\.last)
        return latest.contains { (try? $0.record.decoded(WritingTurnState.self).state) == "running" }
    }

    private func reload() async {
        do { entries = try await host.records(false) } catch { notice = error.localizedDescription }
    }

    private func createConversation() async {
        creating = true; defer { creating = false }
        do {
            let capture = try host.capture()
            let record = try WritingRecord(workId: capture.workId, kind: "conversation", key: "conversation",
                                           payload: WritingRecord.payload(WritingConversation(
                                               title: "会話 \(Date().formatted(date: .abbreviated, time: .shortened))",
                                               documentId: capture.document.id,
                                               readConsent: true
                                           )))
            try await host.append(record); conversationId = record.id; await reload(); notice = nil
        } catch { notice = error.localizedDescription }
    }

    private func send() {
        guard let conversationId, consented else { return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = messages
        let requestedScope = scope
        let id = UUID(); requestId = id
        requestTask = Task { @MainActor in
            defer {
                if requestId == id {
                    requestTask = nil; requestId = nil
                }
            }
            var turn: WritingRecord?
            do {
                let capture = try host.capture()
                let grant = try requestedScope.grant(capture)
                let preferences = AssistantPreferences(defaults: defaults)
                let config = try preferences.configuration(.advice)
                try? await host.synchronize()
                try await WritingPrompts.migrateIfNeeded(host: host, defaults: defaults)
                let prompt = try await WritingPrompts.effective(host: host, defaults: defaults, purpose: .advice)
                try Task.checkCancellation()
                let message = WritingMessage(role: "user", text: question, requestId: id)
                let request = try config.chatRequest(capture: capture, grant: grant, messages: history + [message],
                                                     apiKey: preferences.key(endpoint: config.endpoint), effectivePrompt: prompt)
                let started = try WritingRecord(workId: capture.workId, kind: "request", key: id.uuidString.lowercased(),
                                                payload: WritingRecord.payload(WritingTurnState(state: "running", effectivePrompt: prompt,
                                                                                                conversationId: conversationId,
                                                                                                detail: requestedScope.rawValue)))
                try await host.append(started); turn = started
                try await host.append(WritingRecord(workId: capture.workId, kind: "message", key: conversationId.uuidString.lowercased(),
                                                    payload: WritingRecord.payload(message)))
                input = ""; scope = .advice; notice = "回答を待っています…"; await reload()
                let raw = try await AssistantClient.send(request)
                try Task.checkCancellation()
                guard raw.utf8.count <= 900_000 else { throw AssistantError.tooLarge }
                let answer = try JSONDecoder().decode(AssistantChatAnswer.self, from: Data(raw.utf8))
                // Persist the complete answer, including rejected edits, before any application.
                try await host.append(WritingRecord(workId: capture.workId, kind: "message", key: conversationId.uuidString.lowercased(),
                                                    payload: WritingRecord.payload(WritingMessage(
                                                        role: "assistant",
                                                        text: answer.reply,
                                                        requestId: id
                                                    ))))
                var completed = "completed"
                if !answer.changes.isEmpty {
                    let edit = try WritingEdit(id: id, workId: capture.workId, documentId: capture.document.id,
                                               changes: answer.changes.map { try $0.change() })
                    try await host.append(WritingRecord(id: edit.id, workId: capture.workId, kind: "edit", key: id.uuidString.lowercased(),
                                                        payload: WritingRecord.payload(edit)))
                    do {
                        _ = try edit.applying(to: capture.document, attachments: capture.attachments, grant: grant)
                        try await host.apply(edit, grant); notice = "指定した範囲に反映しました。取り消しできます。"
                    } catch { completed = "rejected"; notice = error.localizedDescription }
                } else {
                    notice = nil
                }
                try await endTurn(started, state: completed, prompt: prompt, conversation: conversationId, detail: notice ?? "回答を保存しました。")
                await reload()
            } catch {
                notice = Task.isCancelled ? WritingError.interrupted.localizedDescription : error.localizedDescription
                if let turn {
                    let message = notice ?? "中断しました。"
                    // A fresh task can save cancellation status; it still uses the captured account/work guard.
                    await Task { @MainActor in
                        try? await endTurn(turn, state: "interrupted", prompt: "", conversation: conversationId, detail: message)
                    }.value
                }
                await reload()
            }
        }
    }

    private func endTurn(_ started: WritingRecord, state: String, prompt: String, conversation: UUID, detail: String) async throws {
        try await host.append(WritingRecord(workId: started.workId, kind: "request", key: started.key, parentId: started.id,
                                            payload: WritingRecord.payload(WritingTurnState(
                                                state: state,
                                                effectivePrompt: prompt,
                                                conversationId: conversation,
                                                detail: detail
                                            ))))
    }

    private func undo(_ id: UUID) async {
        do { try await host.undo(id); notice = "この依頼による変更を取り消しました。" }
        catch { notice = error.localizedDescription }
    }
}
