import EditorKit
import SwiftUI

@main
struct CaretLabApp: App {
    var body: some Scene {
        WindowGroup("ふみにわ カーソル試作") {
            #if FUMINIWA_CARET_EXPERIMENT_TESTS
            Color.clear.frame(width: 300, height: 200)
            #else
            CaretLabView()
            #endif
        }
        .defaultSize(width: 1000, height: 720)
    }
}

private struct CaretLabView: View {
    @AppStorage("animateCaret") private var animateCaret = false
    @AppStorage("draft") private var draft = """
    ここで、日本語の変換や英字の入力を試してみてください。

    「今日は、どんな物語を書こうか」
    机の上に置いたノートを開くと、窓から涼しい風が入ってきた。

    矢印キーでの移動、候補の選択、改行、取り消しも試せます。
    """
    @State private var session = EditorCommandSession()
    @State private var saveNotice = "試し書きは自動保存されます"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("カーソルの動きを試す").font(.headline)
                    Text("ここだけの試し書きです。普段の作品や同期には影響しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("滑らかなカーソル", isOn: $animateCaret).toggleStyle(.switch)
                    .accessibilityIdentifier("caret-lab.motion")
            }
            .padding(20)
            Divider()
            EditorView(chapterKey: "caret-lab-draft", initialText: draft, commandSession: session,
                       configuration: EditorConfiguration(animatesCaret: animateCaret)) { text in
                draft = text
                saveNotice = "試し書きは自動保存されます"
            }
            Divider()
            HStack {
                Text(animateCaret ? "変換中も縦線が追いかけます。候補とは一瞬ずれることがあります。" : "標準のカーソル表示です")
                Spacer()
                Text(saveNotice)
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 720, minHeight: 420)
        .background {
            Button("試し書きを保存") {
                guard session.prepareForDocumentTransition() else { return }
                defer { session.resumeAfterDocumentTransition() }
                if case let .captured(text) = session.captureActiveCommittedText() {
                    draft = text
                    saveNotice = "試し書きを保存しました"
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .hidden()
        }
    }
}
