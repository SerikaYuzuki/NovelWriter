import NovelTextAnalysis
import SwiftUI

struct TextCheckControls: View {
    @Bindable var session: TextCheckSession
    let canCheck: Bool
    let onCheck: () -> Void

    var body: some View {
        Picker("対象", selection: $session.allWork) {
            Text("作品全体").tag(true)
            Text("現在の話").tag(false)
        }
        .frame(minHeight: 44)
        Toggle("会話文（「」『』内）を対象にしない", isOn: $session.excludeDialogue)
            .accessibilityHint("表記ゆれと人物名だけに適用します")
            .frame(minHeight: 44)
        Button(action: onCheck) {
            Label("チェック", systemImage: "text.badge.checkmark").frame(minHeight: 44)
        }
        .disabled(session.isChecking || !canCheck)
        .accessibilityIdentifier("textCheck.run")
        if session.isChecking {
            ProgressView("チェック中")
        }
        Text(session.hasChecked ? "\(session.count)件の指摘" : "「チェック」を押すと端末内で調べます。")
            .font(.callout).monospacedDigit()
        if session.hasChecked, session.isEmpty {
            Text("指摘はありません。無視した指摘は無視一覧で確認できます。")
        }
        if let message = session.message {
            Text(message).foregroundStyle(.secondary)
        }
    }
}

struct TextCheckIgnoredList: View {
    @Bindable var session: TextCheckSession
    var body: some View {
        List {
            if session.ignored.isEmpty {
                Text("無視した指摘はありません。")
            }
            ForEach(session.ignored.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading) {
                    Text(session.ignored[key] ?? "")
                    Button { session.restoreIgnored(key) } label: { Text("無視を解除").frame(minHeight: 44) }
                        .accessibilityHint("次回のチェックで再び表示します")
                }
            }
        }
        .navigationTitle("無視一覧（この端末）")
    }
}
