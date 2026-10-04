import Foundation
import NovelWorkspace
import UIKit
import UniformTypeIdentifiers

@MainActor
protocol IOSPlainTextClipboardWriting {
    func writePlainText(_ text: String) -> Bool
}

@MainActor
struct IOSSystemPlainTextClipboardWriter: IOSPlainTextClipboardWriting {
    func writePlainText(_ text: String) -> Bool {
        // 読み戻しや自動消去は行わず、利用者が明示した1件のplain textだけを書く。
        UIPasteboard.general.items = [[UTType.plainText.identifier: text]]
        return true
    }
}

typealias IOSManuscriptCopyFailure = ManuscriptCopyFailure
typealias IOSManuscriptCopyNotice = ManuscriptCopyNotice
