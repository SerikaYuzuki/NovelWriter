import Foundation

/// 本文のcontext menu actionへ渡す、IME確定済みのexact選択snapshot。
///
/// 範囲は`NSTextView` / `UITextView`を公開APIへ出さず、FoundationのUTF-16
/// `NSRange`だけで表す。生成時とaction実行直前の両方で、同じ範囲と本文であることを
/// platform adapterが検査する。
public struct EditorSelectionContextMenuSnapshot: Sendable, Equatable {
    public let text: String
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

/// App層から本文の標準context menuへ追加できる、platform非依存command。
///
/// EditorKitは表示名と選択snapshotだけを扱い、clipboardや外部service等の副作用は
/// 呼び出し側のactionへ委譲する。actionは本文を書き換えるEditor commandではない。
public struct EditorSelectionContextMenuCommand {
    public let title: String
    public let systemImageName: String?

    private let action: @MainActor (EditorSelectionContextMenuSnapshot) -> Void

    public init(
        title: String,
        systemImageName: String? = nil,
        action: @escaping @MainActor (EditorSelectionContextMenuSnapshot) -> Void
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.action = action
    }

    @MainActor
    func perform(with snapshot: EditorSelectionContextMenuSnapshot) {
        action(snapshot)
    }
}
