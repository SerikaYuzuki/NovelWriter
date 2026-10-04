import NovelTextAnalysis
import NovelWorkspace
import SwiftUI

public struct TextCheckControls: View {
    public init(session: TextCheckSession, canCheck: Bool, onCheck: @escaping () -> Void) {
        self.session = session
        self.canCheck = canCheck
        self.onCheck = onCheck
    }

    @Bindable var session: TextCheckSession
    let canCheck: Bool
    let onCheck: () -> Void

    public var body: some View {
        Picker("対象", selection: $session.allWork) {
            Text("作品全体").tag(true)
            Text("現在の話").tag(false)
        }
        #if os(iOS)
        .frame(minHeight: 44)
        #endif
        Toggle("会話文（「」『』内）を対象にしない", isOn: $session.excludeDialogue)
            .accessibilityHint("表記ゆれと人物名だけに適用します")
        #if os(iOS)
            .frame(minHeight: 44)
        #endif
        Button(action: onCheck) {
            Label("チェック", systemImage: "text.badge.checkmark")
            #if os(iOS)
                .frame(minHeight: 44)
            #endif
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

public struct TextCheckIgnoredList: View {
    public init(session: TextCheckSession) {
        self.session = session
    }

    @Bindable var session: TextCheckSession
    public var body: some View {
        List {
            if session.ignored.isEmpty {
                Text("無視した指摘はありません。")
            }
            ForEach(session.ignored.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading) {
                    Text(session.ignored[key] ?? "")
                    Button { session.restoreIgnored(key) } label: {
                        Text("無視を解除")
                        #if os(iOS)
                            .frame(minHeight: 44)
                        #endif
                    }
                    .accessibilityHint("次回のチェックで再び表示します")
                }
            }
        }
        .navigationTitle("無視一覧（この端末）")
    }
}
