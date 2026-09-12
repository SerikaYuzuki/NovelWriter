import SwiftUI

struct AssistantSettingsView: View {
    let defaults: UserDefaults
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var purpose = AssistantPurpose.proofreading
    @State private var prompts: [String: String] = [:]
    @State private var notice: String?

    var body: some View {
        Form {
            Section("OpenAI対応API") {
                TextField("API URL（/chat/completionsまで）", text: $endpoint)
                    .assistantCredentialInputStyle()
                TextField("モデル名", text: $model).assistantCredentialInputStyle()
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
                        let config = try AssistantConfiguration(endpoint: endpoint, model: model, prompt: "")
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
            model = preferences.model
            prompts = Dictionary(uniqueKeysWithValues: AssistantPurpose.allCases.map { ($0.id, preferences.prompt($0)) })
        }
    }

    private func save() {
        do {
            let config = try AssistantConfiguration(endpoint: endpoint, model: model, prompt: "")
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try AssistantPreferences(defaults: defaults).saveKey(trimmedKey, endpoint: config.endpoint)
            }
            defaults.set(config.endpoint.absoluteString, forKey: "assistant.endpoint")
            defaults.set(config.model, forKey: "assistant.model")
            for purpose in AssistantPurpose.allCases {
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
