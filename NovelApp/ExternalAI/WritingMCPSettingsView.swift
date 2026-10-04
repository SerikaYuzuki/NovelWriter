#if os(macOS)
import AppKit
import SwiftUI

struct WritingMCPSettingsSections: View {
    let controller: WritingMCPController
    @State private var name = ""
    @State private var notice: String?
    var body: some View {
        Section("外部AIとの接続") {
            Text("登録したAIクライアントを信頼し、現在開いている作品へのアクセスを許可します。AIは依頼された範囲を指定して編集し、範囲外の変更はアプリが拒否します。")
            Text("外部AIが依頼を正しく範囲に変換したかはアプリから確認できません。変更は取り消せます。FUMINIWAを終了すると接続も止まります。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.status).font(.caption)
            Text(controller.endpoint).font(.caption).textSelection(.enabled)
            TextField("AIの名前", text: $name, prompt: Text("例：Claude"))
            Button("この接続を信頼して登録") {
                do {
                    _ = try controller.register(name: name); name = ""; notice = "登録しました。接続設定をコピーしてAIクライアントに追加してください。"
                } catch { notice = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section("登録した接続") {
            ForEach(controller.clients) { client in
                HStack {
                    Text(client.name); Spacer()
                    Button("接続設定をコピー") {
                        do {
                            let configuration = try controller.configuration(for: client)
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(configuration, forType: .string)
                            notice = "このMac用の接続設定をコピーしました。"
                        } catch { notice = error.localizedDescription }
                    }
                    Button("解除", role: .destructive) {
                        do { try controller.revoke(client); notice = "接続を解除しました。" }
                        catch { notice = error.localizedDescription }
                    }
                }
            }
            HStack {
                Button("接続を停止") { controller.stop() }
                Button("接続を再開") { controller.start() }
                    .disabled(controller.clients.isEmpty)
            }
        }
        if let notice {
            Text(notice).font(.caption)
        }
    }
}

extension AppState {
    var writingMCPController: WritingMCPController {
        if let writingMCPControllerStorage {
            return writingMCPControllerStorage
        }
        let controller = WritingMCPController(defaults: userDefaults) { [weak self] in self?.writingAssistantHost }
        writingMCPControllerStorage = controller
        return controller
    }
}
#endif
