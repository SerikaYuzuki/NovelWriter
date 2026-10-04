import AppKit
import Foundation
import NovelWorkspace

/// plain textをsystem clipboardへ書く、テスト差し替え可能な境界。
@MainActor
protocol PlainTextClipboardWriting {
    /// clipboardの内容を`text`だけへ置き換えられた場合に`true`を返す。
    func writePlainText(_ text: String) -> Bool
}

/// macOSのgeneral pasteboardへ明示的にplain textを書き込む実装。
@MainActor
struct SystemPlainTextClipboardWriter: PlainTextClipboardWriting {
    func writePlainText(_ text: String) -> Bool {
        // pasteboardを消去する前にitemの文字列化を済ませ、準備失敗時は既存内容を保つ。
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

typealias ManuscriptCopyFailure = NovelWorkspace.ManuscriptCopyFailure
typealias ManuscriptCopyOutcome = NovelWorkspace.ManuscriptCopyOutcome
typealias ManuscriptCopyNotice = NovelWorkspace.ManuscriptCopyNotice
