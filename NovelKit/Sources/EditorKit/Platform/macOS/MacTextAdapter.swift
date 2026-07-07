// `MacTextAdapter`(docs/DESIGN.md 4.3)は、AppKit に触れるコードを EditorKit の
// 中に閉じ込めるための internal 実装である。iOS 向けコンパイル(→ D-013)を壊さない
// よう、必ず `#if canImport(AppKit)` で保護すること(docs/DESIGN.md 9.2)。
// このファイルは iOS ビルドでは中身が空になる。
#if canImport(AppKit)
import AppKit
import SwiftUI

/// `NSTextView`(TextKit 2)を SwiftUI から利用するための internal アダプタ。
///
/// `EditorView`(Public API)の実体。Public API に `NSTextView` を出さないという
/// ルール(docs/DESIGN.md 9.2)を守るため、この型自体は `public` にしない
/// (`EditorView.body` が `some View` として不透明に包んで返す)。
///
/// テキスト所有権ルール(docs/DESIGN.md 4.3, docs/DECISIONS.md D-005)の実装方針:
/// - 本文の流し込みは `chapterKey` が変化したとき(章切り替え時)のみ行う。
///   判定は `TextOwnershipPolicy.shouldLoadText` に切り出してある。SwiftUI の
///   通常の再描画(`updateNSView` の呼び直し)では `textView.string` を書き換えない。
/// - `textDidChange` は、テキストビューが変換中の未確定文字列(IME)を持っていない
///   ときだけ `onTextChange` を呼ぶ(`TextOwnershipPolicy.shouldNotifyTextChange`)。
/// - 章切り替え時、章専用の `UndoManager` を `removeAllActions()` でクリアし、
///   前章の undo 履歴が新しい章に効かないようにする。
struct MacTextAdapter: NSViewRepresentable {
    let chapterKey: AnyHashable
    let initialText: String
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() は常に NSTextView を documentView に持つ")
        }

        assertTextKit2(textView)
        configure(textView)

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.currentChapterKey = chapterKey

        textView.string = initialText
        context.coordinator.undoManager.removeAllActions()

        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        // クロージャは SwiftUI の再描画のたびに再生成されるため、常に最新のものへ
        // 差し替える(Coordinator はビューのライフサイクルを通じて生き続ける)。
        context.coordinator.onTextChange = onTextChange

        guard let textView = context.coordinator.textView else { return }

        guard TextOwnershipPolicy.shouldLoadText(
            previousChapterKey: context.coordinator.currentChapterKey,
            newChapterKey: chapterKey
        ) else {
            // 同じ章のままの再描画。編集中の本文を外部から上書きしない
            // (テキスト所有権ルール, docs/DESIGN.md 4.3, D-005)。
            return
        }

        context.coordinator.currentChapterKey = chapterKey
        textView.string = initialText
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // 章切り替え: 前章の undo 履歴が新しい章に効いてはならない。
        context.coordinator.undoManager.removeAllActions()
    }

    /// `NSTextView` が TextKit 2 で構築されていることを検証する。
    ///
    /// `layoutManager` への直接アクセスは TextKit 1 互換レイヤーを生成させ、
    /// TextKit 2 を暗黙に無効化してしまう(docs/DECISIONS.md D-006)。この関数は
    /// `layoutManager` に一切触れず、`textLayoutManager` の存在だけを確認する。
    private func assertTextKit2(_ textView: NSTextView) {
        assert(
            textView.textLayoutManager != nil,
            "NSTextView が TextKit 1 にフォールバックしています。" +
                "layoutManager への直接アクセスが原因になっていないか確認してください(D-006)。"
        )
    }

    /// 日本語の長文執筆に適した、プレーンテキストのエディタとして設定する。
    private func configure(_ textView: NSTextView) {
        // プレーンテキスト。装飾はモデルの責務ではない。
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true

        // 執筆の邪魔になる自動整形は無効化する。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        // 日本語の長文執筆が読みやすいデフォルト(システムフォント16pt、行間やや広め)。
        let font = NSFont.systemFont(ofSize: 16)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.4
        textView.font = font
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraphStyle]
        textView.textContainerInset = NSSize(width: 12, height: 16)

        // 幅追従・縦スクロールのみ。
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
    }

    /// `NSTextViewDelegate` を実装し、テキスト所有権ルールを守りながら
    /// モデルへの通知・undo管理を行う。
    ///
    /// `UndoManager` は Swift では `@MainActor` 隔離されているため、この型全体を
    /// `@MainActor` にする(SwiftUI の `NSViewRepresentable` 呼び出しはもともと
    /// メインスレッドで行われるため、実害はない)。
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        weak var textView: NSTextView?
        var currentChapterKey: AnyHashable?

        /// 章専用の undo 管理。`NSResponder.undoManager`(ウィンドウ共有)には
        /// 頼らず、`undoManager(for:)` でこの専用インスタンスを返すことで、
        /// 章切り替え時に他のUIへ影響を与えずに履歴をクリアできる。
        let undoManager = UndoManager()

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            guard TextOwnershipPolicy.shouldNotifyTextChange(
                hasMarkedText: textView.hasMarkedText()
            ) else {
                // IME変換中は通知しない。変換確定後の textDidChange で
                // 最新の全文が届く(docs/DESIGN.md 4.3)。
                return
            }

            onTextChange(textView.string)
        }

        func undoManager(for _: NSTextView) -> UndoManager? {
            undoManager
        }
    }
}
#endif
