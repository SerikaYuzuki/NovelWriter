@testable import EditorKit
import Foundation
import Testing

/// ``EditorContext`` を実 `NSTextView` なしでテストするための単純な実装。
private final class FakeEditorContext: EditorContext {
    var string: String
    var isIMEComposing: Bool

    init(string: String = "", isIMEComposing: Bool = false) {
        self.string = string
        self.isIMEComposing = isIMEComposing
    }

    func lineRange(at location: Int) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }
}

/// 複数の `SpyPlugin` にまたがる呼び出し順序を記録する共有レコーダー。
private final class CallRecorder {
    private(set) var calls: [String] = []

    func record(_ name: String) {
        calls.append(name)
    }
}

/// 呼ばれた回数・呼ばれた順序を記録するだけのスパイプラグイン。
private final class SpyPlugin: EditorPlugin {
    let name: String
    let shouldChangeResult: EditorAction
    let recorder: CallRecorder?
    private(set) var shouldChangeCallCount = 0
    private(set) var didChangeCallCount = 0

    init(name: String, shouldChangeResult: EditorAction = .allow, recorder: CallRecorder? = nil) {
        self.name = name
        self.shouldChangeResult = shouldChangeResult
        self.recorder = recorder
    }

    func shouldChange(context _: EditorContext, range _: NSRange, replacement _: String) -> EditorAction {
        shouldChangeCallCount += 1
        recorder?.record(name)
        return shouldChangeResult
    }

    func didChange(context _: EditorContext) {
        didChangeCallCount += 1
        recorder?.record(name)
    }
}

/// ``EditorPluginPipeline``(docs/DESIGN.md 4.4)の単体テスト。
/// プラグインの実行順序・確定ロジック・IMEGuardによるスキップを、AppKitに
/// 依存しない ``FakeEditorContext`` を使って検証する。
struct EditorPluginPipelineTests {
    private let caretRange = NSRange(location: 0, length: 0)

    @Test("すべてのプラグインが.allowを返した場合、パイプライン全体も.allowを返す")
    func allAllowResultsInAllow() {
        let firstPlugin = SpyPlugin(name: "A")
        let secondPlugin = SpyPlugin(name: "B")
        let pipeline = EditorPluginPipeline(plugins: [firstPlugin, secondPlugin])

        let action = pipeline.shouldChange(context: FakeEditorContext(), range: caretRange, replacement: "x")

        #expect(action == .allow)
        #expect(firstPlugin.shouldChangeCallCount == 1)
        #expect(secondPlugin.shouldChangeCallCount == 1)
    }

    @Test("最初に.allow以外を返したプラグインで確定し、以降のプラグインは実行されない")
    func firstNonAllowWins() {
        let replaceAction = EditorAction.replace(range: NSRange(location: 0, length: 0), text: "X", caretOffset: 1)
        let laterAction = EditorAction.replace(range: NSRange(location: 1, length: 1), text: "Y", caretOffset: 0)
        let firstPlugin = SpyPlugin(name: "A")
        let secondPlugin = SpyPlugin(name: "B", shouldChangeResult: replaceAction)
        let thirdPlugin = SpyPlugin(name: "C", shouldChangeResult: laterAction)
        let pipeline = EditorPluginPipeline(plugins: [firstPlugin, secondPlugin, thirdPlugin])

        let action = pipeline.shouldChange(context: FakeEditorContext(), range: caretRange, replacement: "x")

        #expect(action == replaceAction)
        #expect(firstPlugin.shouldChangeCallCount == 1)
        #expect(secondPlugin.shouldChangeCallCount == 1)
        #expect(thirdPlugin.shouldChangeCallCount == 0)
    }

    @Test("IMEGuardPluginは変換中に.allowSkippingRemainingを返し、後続プラグインを実行させない")
    func imeGuardSkipsRemainingWhileComposing() {
        let indentTriggeringPlugin = SpyPlugin(
            name: "wouldReplace",
            shouldChangeResult: .replace(range: NSRange(location: 0, length: 0), text: "\n\u{3000}", caretOffset: 2)
        )
        let pipeline = EditorPluginPipeline(plugins: [IMEGuardPlugin(), indentTriggeringPlugin])
        let context = FakeEditorContext(string: "本文", isIMEComposing: true)

        let action = pipeline.shouldChange(
            context: context,
            range: NSRange(location: context.string.utf16.count, length: 0),
            replacement: "\n"
        )

        #expect(action == .allowSkippingRemaining)
        #expect(indentTriggeringPlugin.shouldChangeCallCount == 0)
    }

    @Test("IMEGuardPluginは非変換中なら.allowを返し、後続プラグインが実行される")
    func imeGuardAllowsWhenNotComposing() {
        let followingPlugin = SpyPlugin(name: "A")
        let pipeline = EditorPluginPipeline(plugins: [IMEGuardPlugin(), followingPlugin])
        let context = FakeEditorContext(string: "本文", isIMEComposing: false)

        let action = pipeline.shouldChange(context: context, range: caretRange, replacement: "x")

        #expect(action == .allow)
        #expect(followingPlugin.shouldChangeCallCount == 1)
    }

    @Test("実際のIMEGuardPlugin + IndentPluginの組み合わせで、変換中は改行の自動字下げが抑止される")
    func realPipelineSuppressesIndentWhileComposing() {
        let pipeline = EditorPluginPipeline(plugins: [IMEGuardPlugin(), IndentPlugin()])
        let text = "本文"
        let composingContext = FakeEditorContext(string: text, isIMEComposing: true)
        let notComposingContext = FakeEditorContext(string: text, isIMEComposing: false)
        let range = NSRange(location: (text as NSString).length, length: 0)

        let composingAction = pipeline.shouldChange(context: composingContext, range: range, replacement: "\n")
        let normalAction = pipeline.shouldChange(context: notComposingContext, range: range, replacement: "\n")

        #expect(composingAction == .allowSkippingRemaining)
        #expect(normalAction == .replace(range: range, text: "\n\u{3000}", caretOffset: 2))
    }

    @Test("didChangeは登録順にすべてのプラグインへ届く")
    func didChangeReachesAllPluginsInOrder() {
        let recorder = CallRecorder()
        let firstPlugin = SpyPlugin(name: "A", recorder: recorder)
        let secondPlugin = SpyPlugin(name: "B", recorder: recorder)
        let pipeline = EditorPluginPipeline(plugins: [firstPlugin, secondPlugin])

        pipeline.didChange(context: FakeEditorContext())

        #expect(firstPlugin.didChangeCallCount == 1)
        #expect(secondPlugin.didChangeCallCount == 1)
        #expect(recorder.calls == ["A", "B"])
    }
}
