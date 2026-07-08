import SwiftUI

/// 本文エディタを提供する SwiftUI View。
///
/// macOS では `NSTextView`(TextKit 2)をラップした実装(`MacTextAdapter`)を表示する。
/// iOS 版はまだ実装しておらず、プレースホルダの View を表示する
/// (docs/DESIGN.md 7章 Phase 7 で `UITextView` アダプタに置き換える予定)。
///
/// Public API に `NSTextView` / `UITextView` を一切出さない(docs/DESIGN.md 9.2)。
///
/// ## テキスト所有権ルール(docs/DESIGN.md 4.3, docs/DECISIONS.md D-005)
///
/// 編集中の本文の「正」はプラットフォーム側のテキストビューであり、`EditorView` は
/// それを一方的に上書きしない。
///
/// - 本文の流し込みは ``chapterKey`` が変化したとき(= 章切り替え時)のみ行う。
///   同じ ``chapterKey`` のまま SwiftUI の再描画が走っても、``initialText`` は
///   再適用しない(編集中の内容を保持する)。
/// - 本文が変わるたびに ``onTextChange`` が呼ばれる。ただし IME 変換中は呼ばれない
///   (変換確定後の通知で最新の全文が届く)。
/// - 素朴な `Binding<String>` による双方向同期は行わない(D-005 で禁止)。
public struct EditorView: View {
    private let chapterKey: AnyHashable
    private let initialText: String
    private let selectionRequest: EditorSelectionRequest?
    private let configuration: EditorConfiguration
    private let onTextChange: (String) -> Void

    /// - Parameters:
    ///   - chapterKey: 表示中の章を一意に識別するキー(例: 章ID)。このキーが
    ///     変化したときだけ ``initialText`` を本文へ流し込む。呼び出し側は
    ///     章を切り替えるたびに異なるキーを渡すこと。
    ///   - initialText: ``chapterKey`` が変化したときにテキストビューへ流し込む
    ///     本文。編集中は無視される(所有権はテキストビュー側にあるため)。
    ///   - selectionRequest: 本文中の指定範囲を選択し、表示位置へスクロールする
    ///     リクエスト。検索ジャンプなど、本文を書き換えない操作に使う。
    ///   - configuration: エディタの表示設定。本文は流し直さず、表示属性だけを更新する。
    ///   - onTextChange: 本文が変更されるたびに、そのときの全文を渡して呼び出される
    ///     コールバック。IME 変換中には呼ばれない。
    public init(
        chapterKey: AnyHashable,
        initialText: String,
        selectionRequest: EditorSelectionRequest? = nil,
        configuration: EditorConfiguration = EditorConfiguration(),
        onTextChange: @escaping (String) -> Void
    ) {
        self.chapterKey = chapterKey
        self.initialText = initialText
        self.selectionRequest = selectionRequest
        self.configuration = configuration
        self.onTextChange = onTextChange
    }

    public var body: some View {
        #if canImport(AppKit)
        MacTextAdapter(
            chapterKey: chapterKey,
            initialText: initialText,
            selectionRequest: selectionRequest,
            configuration: configuration,
            onTextChange: onTextChange
        )
        #elseif canImport(UIKit)
        UnimplementedEditorView()
        #endif
    }
}

#if canImport(UIKit) && !canImport(AppKit)
/// iOS 版はまだ実装していないことを示すプレースホルダ View。
///
/// `UITextView` アダプタは docs/DESIGN.md ロードマップの Phase 7 で追加する
/// (docs/DECISIONS.md D-013)。それまでは iOS 向けビルドが通ることだけを保証する。
struct UnimplementedEditorView: View {
    var body: some View {
        Text("iOS版は未実装です")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
    }
}
#endif
