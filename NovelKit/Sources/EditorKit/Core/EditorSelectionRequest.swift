import Foundation

/// `EditorView` に本文選択とスクロールを依頼する値。
///
/// AppKit / UIKit の型を公開 API に出さないため、選択範囲は Foundation の
/// `NSRange`(UTF-16 単位)だけで表現する。`id` が変わるたびに、同じ範囲でも
/// 新しいジャンプリクエストとして扱われる。
public struct EditorSelectionRequest: Equatable, Sendable {
    public let id: UUID
    public let range: NSRange

    public init(id: UUID = UUID(), range: NSRange) {
        self.id = id
        self.range = range
    }
}
