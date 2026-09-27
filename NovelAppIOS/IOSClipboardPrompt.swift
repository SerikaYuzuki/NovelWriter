import Foundation
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

enum IOSManuscriptCopyFailure: Sendable, Equatable {
    case staleContext
    case compositionInProgress
    case emptyContent
    case contentTooLarge
    case copyPreparationFailed
    case clipboardWriteFailed
}

struct IOSManuscriptCopyNotice: Identifiable, Sendable, Equatable {
    let id = UUID()
    let failure: IOSManuscriptCopyFailure?

    static let success = IOSManuscriptCopyNotice(failure: nil)

    var title: String {
        failure == nil ? "コピーしました" : "コピーできませんでした"
    }

    var message: String {
        switch failure {
        case nil:
            "クリップボードへコピーしました。"
        case .staleContext:
            "対象の作品、章、または話が変わりました。対象を確認して、もう一度コピーしてください。"
        case .compositionInProgress:
            "日本語入力の変換を確定してから、もう一度コピーしてください。"
        case .emptyContent:
            "対象本文が空です。本文を入力するか、空でない範囲を選択してください。"
        case .contentTooLarge:
            "対象が大きすぎるため、内容を切り詰めずコピーを中止しました。"
        case .copyPreparationFailed:
            "コピーする文字列を準備できませんでした。"
        case .clipboardWriteFailed:
            "システムクリップボードへ書き込めませんでした。"
        }
    }
}
