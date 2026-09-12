import SwiftUI

/// Requests expire on context change; the host owns guarded native-editor application.
struct AssistantPanelView: View {
    let defaults: UserDefaults
    let contextID: String
    let episodeTitle: String
    let capture: () throws -> AssistantManuscript
    let close: () -> Void
    var applyProofreading: ((AssistantManuscript, String) -> Bool)?
    @State private var pendingPurpose = AssistantPurpose.proofreading
    @State private var purpose = AssistantPurpose.proofreading
    @State private var answer = ""
    @State private var notice: String?
    @State private var pending: AssistantManuscript?
    @State private var pendingConfiguration: AssistantConfiguration?
    @State private var showingSettings = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI支援").font(.headline)
                Spacer()
                Button("設定", systemImage: "gearshape") { showingSettings = true }
                    .labelStyle(.iconOnly)
                Button("閉じる", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            Text("対象：現在の話「\(episodeTitle)」").font(.caption)
            Picker("用途", selection: $purpose) {
                ForEach(AssistantPurpose.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Button("本文を確認して送信…", action: prepare)
                    .disabled(requestTask != nil)
                if requestTask != nil {
                    ProgressView().controlSize(.small)
                    Button("中止") { cancel(); notice = "中止しました。" }
                }
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                AssistantMarkdownView(source: answer.isEmpty ? "校正・感想・アドバイスがここに表示されます。" : answer)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                AssistantSettingsView(defaults: defaults)
                    .toolbar { Button("閉じる") { showingSettings = false } }
            }.frame(minWidth: 340, minHeight: 480)
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: {
            if !$0 {
                pending = nil; pendingConfiguration = nil
            }
        })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("送信する本文").font(.headline)
                if pendingPurpose == .proofreading, applyProofreading != nil {
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
        .onChange(of: contextID) { _, _ in reset() }
        .onDisappear { reset() }
    }

    private func prepare() {
        do {
            let configuration = try AssistantPreferences(defaults: defaults).configuration(purpose)
            let manuscript = try capture()
            // Validate size before showing a preview; do not read credentials until Send.
            _ = try configuration.request(manuscript: manuscript, apiKey: "validation-only")
            pendingPurpose = purpose
            pendingConfiguration = configuration
            pending = manuscript
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    private func send() {
        guard let manuscript = pending, let config = pendingConfiguration else { return }
        pending = nil
        pendingConfiguration = nil
        do {
            let key = try AssistantPreferences(defaults: defaults).key(endpoint: config.endpoint)
            let requestPurpose = pendingPurpose
            let effectiveConfig = try AssistantConfiguration(endpoint: config.endpoint.absoluteString, model: config.model,
                                                             prompt: config.prompt + (requestPurpose == .proofreading && applyProofreading != nil
                                                                 ? "\n校正した全文をJSONオブジェクト {\"content\":\"校正後の全文\"} のみで返してください。説明・引用・Markdown囲みは不要です。省略せず、校正対象外の文字、改行、空白を保持してください。"
                                                                 : "\n回答はMarkdownで記述してください。"))
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
                    let result = try await AssistantClient.send(request)
                    guard !Task.isCancelled, requestID == id else { return }
                    if requestPurpose == .proofreading, let applyProofreading {
                        let revised = try AssistantClient.proofreadContent(result)
                        guard applyProofreading(manuscript, revised) else {
                            notice = "本文や対象が変わったため反映しませんでした。入力を確定して再実行してください。"
                            return
                        }
                        notice = revised == manuscript.content ? "修正はありませんでした。" : "校正を反映しました。追加・変更箇所を黄色で表示しています。削除箇所には色が付きません。保存で色を消せます。取り消しも可能です。"
                    } else {
                        answer = result
                    }
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    notice = (error as? AssistantError)?.localizedDescription ?? "通信できませんでした。接続を確認して再試行してください。"
                }
            }
        } catch { notice = error.localizedDescription }
    }

    private func cancel() {
        requestID = nil; requestTask?.cancel(); requestTask = nil
    }

    private func reset() {
        cancel(); pending = nil; pendingConfiguration = nil; answer = ""; notice = nil
    }
}

/// Native Markdown presentation: inline emphasis/links plus headings, lists, quotes and fenced code.
private struct AssistantMarkdownView: View {
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(source.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                let fenced = source.components(separatedBy: "\n").prefix(index).count(where: { $0.hasPrefix("```") }) % 2 == 1
                if line.hasPrefix("```") {
                    Divider()
                } else if fenced {
                    Text(verbatim: line).font(.system(.body, design: .monospaced))
                } else if line.hasPrefix("#") {
                    Text(.init(String(line.drop(while: { $0 == "#" || $0 == " " }))))
                        .font(line.hasPrefix("###") ? .headline : .title3).bold()
                } else {
                    Text(.init(line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line))
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
