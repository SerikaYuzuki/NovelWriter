import SwiftUI

/// View-local responses expire on document/episode change. This component cannot edit a manuscript.
struct AssistantPanelView: View {
    let defaults: UserDefaults
    let contextID: String
    let episodeTitle: String
    let capture: () throws -> AssistantManuscript
    let close: () -> Void
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
                Text(answer.isEmpty ? "校正・感想・アドバイスがここに表示されます。" : answer)
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
            let request = try config.request(manuscript: manuscript, apiKey: key)
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
                    answer = result
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
