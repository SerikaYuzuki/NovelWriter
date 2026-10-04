import NovelCore
import NovelUI
import NovelWritingSupport
import SwiftUI

/// Requests expire on context change; the host owns guarded native-editor application.
struct AssistantPanelView: View {
    let defaults: UserDefaults
    let contextID: String
    let episodeTitle: String
    let currentEpisodeID: EpisodeID?
    let capture: () throws -> AssistantManuscript
    let close: () -> Void
    var applyProofreading: ((AssistantManuscript, String) -> Bool)?
    var saveFeedback: ((AssistantFeedback) async -> Bool)?
    var writingHost: WritingAssistantHost?
    var chapters: [Chapter] = []
    var captureScope: ((AssistantScope) throws -> AssistantManuscript)?
    @State private var scope = AssistantScope.current
    @State private var pendingPurpose = AssistantPurpose.proofreading
    @State private var purpose = AssistantPurpose.proofreading
    @State private var answer = ""
    @State private var unsavedFeedback: AssistantFeedback?
    @State private var isSavingFeedback = false
    @State private var notice: String?
    @State private var pending: AssistantManuscript?
    @State private var pendingConfiguration: AssistantConfiguration?
    #if os(iOS)
    @State private var showingSettings = false
    #endif
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI支援", systemImage: "sparkles").font(.headline)
                    .foregroundStyle(FuminiwaColor.accent.color)
                    .symbolRenderingMode(.hierarchical)
                Spacer()
                #if os(macOS)
                SettingsLink { Label("設定", systemImage: "gearshape") }
                    .labelStyle(.iconOnly)
                    .help("設定の「AI支援」を開く")
                #else
                Button("設定", systemImage: "gearshape") { showingSettings = true }
                    .labelStyle(.iconOnly)
                #endif
                Button("閉じる", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            Picker("用途", selection: $purpose) {
                ForEach(AssistantPurpose.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if purpose == .advice, let writingHost {
                AssistantChatView(host: writingHost, defaults: defaults, chapters: chapters,
                                  currentEpisodeID: currentEpisodeID, referenceScope: $scope)
            } else {
                if purpose == .proofreading {
                    Text("校正する範囲：現在の1話（\(episodeTitle)）")
                        .font(.subheadline)
                } else {
                    AssistantScopeSelector(chapters: chapters, currentID: currentEpisodeID, scope: $scope)
                }
                HStack {
                    Button("本文を確認して送信…", action: prepare)
                        .disabled(requestTask != nil || effectiveScope.selectedEpisodeIDs(
                            chapters: chapters, currentID: currentEpisodeID
                        ).isEmpty)
                    if requestTask != nil {
                        ProgressView().controlSize(.small)
                        Button("中止") { cancel(); notice = "中止しました。" }
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if unsavedFeedback != nil {
                    Button(isSavingFeedback ? "保存中…" : "回答を保存し直す") {
                        Task { await persistFeedback() }
                    }.disabled(isSavingFeedback)
                }
                Divider()
                ScrollView {
                    AssistantMarkdownView(source: answer.isEmpty ? "校正・感想・アドバイスがここに表示されます。" : answer)
                        .textSelection(.enabled)
                        .padding(Spacing.medium)
                        .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .modifier(WritingSyncVisibility(host: writingHost))
        .padding(16)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(FuminiwaColor.paper.color)
        #if os(iOS)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    AssistantSettingsView(defaults: defaults, writingHost: writingHost)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showingSettings = false } } }
                }.frame(minWidth: 340, minHeight: 480)
            }
        #endif
            .sheet(isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil; pendingConfiguration = nil
                }
            })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(pendingPurpose.rawValue)に送信する本文").font(.headline)
                    if pendingPurpose != .proofreading {
                        Text("回答は「感想・アドバイス」に日時付きで保存し、作品と一緒に同期します。")
                            .font(.caption)
                    }
                    if pendingPurpose == .proofreading, canApplyProofreading {
                        Text("校正が完了すると本文を上書きし、変更箇所を色で示します。取り消しできます。")
                            .font(.caption)
                    }
                    Text("送信先：\(pendingConfiguration?.endpoint.absoluteString ?? "")").font(.caption)
                    Text("\(pending?.title ?? "") ・ \(pending?.content.count ?? 0)文字")
                    ScrollView { Text(pending?.content ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Button("キャンセル") { pending = nil; pendingConfiguration = nil }
                        Spacer()
                        Button("この本文を送信", action: send).buttonStyle(.borderedProminent)
                    }
                }.padding(20).frame(minWidth: 340, idealWidth: 500, minHeight: 420)
            }
            .onChange(of: contextID) { _, _ in reset(); scope = .current }
            .onChange(of: purpose) { _, _ in reset() }
            .onChange(of: scope) { _, _ in reset() }
            .onChange(of: chapters.map { $0.id.description + $0.episodes.map(\.id.description).joined() }) { _, _ in reset(); scope = .current }
            .onDisappear { reset() }
    }

    private var effectiveScope: AssistantScope {
        scope.forPurpose(purpose)
    }

    private var canApplyProofreading: Bool {
        effectiveScope == .current && applyProofreading != nil
    }

    private func prepare() {
        let id = UUID(); requestID = id
        let chosenPurpose = purpose
        requestTask = Task { @MainActor in
            defer {
                if requestID == id {
                    requestTask = nil
                }
            }
            do {
                let preferences = AssistantPreferences(defaults: defaults)
                let configuration: AssistantConfiguration
                if let writingHost {
                    try? await writingHost.synchronizeNow()
                    try await WritingPrompts.migrateIfNeeded(host: writingHost, defaults: defaults)
                    let prompt = try await WritingPrompts.effective(host: writingHost, defaults: defaults, purpose: chosenPurpose)
                    configuration = try AssistantConfiguration(endpoint: preferences.endpoint, model: preferences.model(chosenPurpose),
                                                               prompt: prompt + "\n" + chosenPurpose.requestInstruction)
                } else {
                    configuration = try preferences.configuration(chosenPurpose)
                }
                guard !Task.isCancelled, requestID == id else { return }
                let manuscript: AssistantManuscript
                if effectiveScope == .current {
                    manuscript = try capture()
                } else {
                    guard let captureScope else { throw AssistantError.emptyContent }
                    manuscript = try captureScope(effectiveScope)
                }
                _ = try configuration.request(manuscript: manuscript, apiKey: "validation-only")
                pendingPurpose = chosenPurpose; pendingConfiguration = configuration; pending = manuscript; notice = nil
            } catch {
                if requestID == id {
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func send() {
        guard let manuscript = pending, let config = pendingConfiguration else { return }
        pending = nil
        pendingConfiguration = nil
        do {
            let key = try AssistantPreferences(defaults: defaults).key(endpoint: config.endpoint)
            let requestPurpose = pendingPurpose
            let shouldApply = canApplyProofreading
            let effectiveConfig = try AssistantConfiguration(endpoint: config.endpoint.absoluteString, model: config.model,
                                                             prompt: config.prompt + (requestPurpose == .proofreading && shouldApply
                                                                 ? "\n校正した全文をJSONオブジェクト {\"content\":\"校正後の全文\"} のみで返してください。説明・引用・Markdown囲みは不要です。省略せず、校正対象外の文字、改行、空白を保持してください。"
                                                                 : "\n回答はMarkdownで記述してください。"),
                                                             replacesManuscript: requestPurpose == .proofreading && shouldApply)
            let request = try effectiveConfig.request(manuscript: manuscript, apiKey: key)
            let id = UUID()
            requestID = id
            answer = ""
            requestTask = Task { @MainActor in
                defer {
                    if requestID == id {
                        requestTask = nil
                    }
                }
                do {
                    if let writingHost {
                        struct RequestRecord: Encodable { let state: String; let effectivePrompt: String; let purpose: String }
                        try await writingHost.append(WritingRecord(
                            workId: writingHost.capture().workId,
                            kind: "request",
                            key: id.uuidString.lowercased(),
                            payload: WritingRecord.payload(RequestRecord(
                                state: "sent",
                                effectivePrompt: effectiveConfig.prompt,
                                purpose: requestPurpose.id
                            ))
                        ))
                    }
                    let result = try await AssistantClient.send(request)
                    guard !Task.isCancelled, requestID == id else { return }
                    if requestPurpose == .proofreading, shouldApply, let applyProofreading {
                        let revised = try AssistantClient.proofreadContent(result)
                        guard applyProofreading(manuscript, revised) else {
                            notice = "本文や対象が変わったため反映しませんでした。入力を確定して再実行してください。"
                            return
                        }
                        notice = revised == manuscript.content ? "修正はありませんでした。" : "校正を反映しました。追加・変更箇所を黄色で表示しています。削除箇所には色が付きません。保存で色を消せます。取り消しも可能です。"
                    } else {
                        answer = result
                        if requestPurpose != .proofreading {
                            unsavedFeedback = AssistantFeedback(id: UUID(), purpose: requestPurpose,
                                                                scopeTitle: manuscript.title, createdAt: Date(), markdown: result)
                            await persistFeedback()
                        }
                    }
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    notice = (error as? AssistantError)?.localizedDescription ?? "通信できませんでした。接続を確認して再試行してください。"
                }
            }
        } catch { notice = error.localizedDescription }
    }

    private func persistFeedback() async {
        guard let feedback = unsavedFeedback, let saveFeedback, !isSavingFeedback else { return }
        isSavingFeedback = true
        defer { isSavingFeedback = false }
        let saved = await saveFeedback(feedback)
        guard unsavedFeedback?.id == feedback.id else { return }
        if saved {
            unsavedFeedback = nil
            notice = "「感想・アドバイス」に保存しました。"
        } else {
            notice = "回答を保存できませんでした。入力を確定して「回答を保存し直す」を押してください。"
        }
    }

    private func cancel() {
        requestID = nil; requestTask?.cancel(); requestTask = nil
    }

    private func reset() {
        cancel(); pending = nil; pendingConfiguration = nil; answer = ""; notice = nil; unsavedFeedback = nil
    }
}
