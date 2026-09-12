import SwiftUI

struct AssistantSettingsView: View {
    let defaults: UserDefaults
    @State private var endpoint = ""
    @State private var models: [String: String] = [:]
    @State private var catalog: [String] = []
    @State private var loadingModels = false
    @State private var apiKey = ""
    @State private var purpose = AssistantPurpose.proofreading
    @State private var prompts: [String: String] = [:]
    @State private var notice: String?

    var body: some View {
        Form {
            Section("OpenAI対応API") {
                TextField("API URL（/responses または /chat/completions）", text: $endpoint)
                    .assistantCredentialInputStyle()
                ForEach(AssistantPurpose.allCases) { item in
                    TextField("\(item.rawValue)のモデル", text: Binding(
                        get: { models[item.id] ?? "" }, set: { models[item.id] = $0 }
                    )).assistantCredentialInputStyle()
                    if !catalog.isEmpty {
                        Picker("\(item.rawValue)のモデルを一覧から選択", selection: Binding(
                            get: { models[item.id] ?? "" }, set: { models[item.id] = $0 }
                        )) {
                            Text(models[item.id] ?? "未選択").tag(models[item.id] ?? "")
                            ForEach(catalog.filter { $0 != models[item.id] }, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Button(loadingModels ? "取得中…" : "OpenAIの最新モデル一覧を取得") {
                    Task { await refreshModels() }
                }.disabled(loadingModels)
                Text("一覧は新しい順です。用途に対応したテキスト生成モデルを選択してください。")
                    .font(.caption)
                SecureField("APIキー（変更時のみ入力）", text: $apiKey)
                    .assistantCredentialInputStyle()
                Text("設定した送信先へ本文を送ります。利用料金・保存方針は各サービスに従います。キーはこの端末のKeychainに保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("プロンプト") {
                Picker("用途", selection: $purpose) {
                    ForEach(AssistantPurpose.allCases) { Text($0.rawValue).tag($0) }
                }
                TextEditor(text: Binding(
                    get: { prompts[purpose.id] ?? purpose.defaultPrompt },
                    set: { prompts[purpose.id] = $0 }
                ))
                .frame(minHeight: 140)
                .accessibilityLabel("用途別プロンプト")
                Button("この用途の初期値に戻す") { prompts[purpose.id] = purpose.defaultPrompt }
            }
            Section {
                Button("設定を保存", action: save)
                Button("この送信先のAPIキーを削除", role: .destructive) {
                    do {
                        let config = try AssistantConfiguration(endpoint: endpoint, model: "configuration", prompt: "")
                        try AssistantPreferences(defaults: defaults).deleteKey(endpoint: config.endpoint)
                        apiKey = ""
                        notice = "APIキーを削除しました。"
                    } catch { notice = error.localizedDescription }
                }
                if let notice {
                    Text(notice).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI支援の設定")
        .onAppear {
            let preferences = AssistantPreferences(defaults: defaults)
            endpoint = preferences.endpoint
            models = Dictionary(uniqueKeysWithValues: AssistantPurpose.allCases.map { ($0.id, preferences.model($0)) })
            prompts = Dictionary(uniqueKeysWithValues: AssistantPurpose.allCases.map { ($0.id, preferences.prompt($0)) })
        }
    }

    @MainActor
    private func refreshModels() async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            let config = try AssistantConfiguration(endpoint: endpoint, model: "catalog", prompt: "")
            guard config.endpoint.host == "api.openai.com" else {
                notice = "OpenAIのAPI URLを設定してください。"
                return
            }
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = try enteredKey.isEmpty ? AssistantPreferences(defaults: defaults).key(endpoint: config.endpoint) : enteredKey
            catalog = try await AssistantClient.models(apiKey: key)
            notice = "利用可能なモデルを取得しました。"
        } catch { notice = error.localizedDescription }
    }

    private func save() {
        do {
            let config = try AssistantConfiguration(endpoint: endpoint, model: "configuration", prompt: "")
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try AssistantPreferences(defaults: defaults).saveKey(trimmedKey, endpoint: config.endpoint)
            }
            defaults.set(config.endpoint.absoluteString, forKey: "assistant.endpoint")

            for purpose in AssistantPurpose.allCases {
                defaults.set(models[purpose.id] ?? "", forKey: "assistant.model.\(purpose.id)")
                defaults.set(prompts[purpose.id] ?? purpose.defaultPrompt, forKey: "assistant.prompt.\(purpose.id)")
            }
            apiKey = ""
            notice = "設定を保存しました。"
        } catch { notice = error.localizedDescription }
    }
}

private extension View {
    func assistantCredentialInputStyle() -> some View {
        #if os(iOS)
        autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        autocorrectionDisabled()
        #endif
    }
}
