import AppKit
import Foundation

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

enum AIClipboardPromptCopyFailure: Sendable, Equatable {
    case staleContext
    case compositionInProgress
    case emptyContent
    case contentTooLarge
    case promptEncodingFailed
    case clipboardWriteFailed
}

enum AIClipboardPromptCopyOutcome: Sendable, Equatable {
    case success
    case failure(AIClipboardPromptCopyFailure)
}

/// prompt本文を持たない、コピー結果の一時通知。
struct AIClipboardPromptCopyNotice: Identifiable, Sendable, Equatable {
    let id: UUID
    let outcome: AIClipboardPromptCopyOutcome

    init(id: UUID = UUID(), outcome: AIClipboardPromptCopyOutcome) {
        self.id = id
        self.outcome = outcome
    }

    var title: String {
        switch outcome {
        case .success:
            "プロンプトをコピーしました"
        case .failure:
            "プロンプトをコピーできませんでした"
        }
    }

    var message: String {
        switch outcome {
        case .success:
            "プロンプトをシステムクリップボードへコピーしました。AIチャットには送信していません。"
        case let .failure(failure):
            failure.message
        }
    }
}

private extension AIClipboardPromptCopyFailure {
    var message: String {
        switch self {
        case .staleContext:
            "対象の作品、章、または話が変わりました。対象を確認して、もう一度コピーしてください。"
        case .compositionInProgress:
            "日本語入力の変換を確定してから、もう一度コピーしてください。"
        case .emptyContent:
            "対象本文が空です。本文を入力するか、空でない範囲を選択してください。"
        case .contentTooLarge:
            "対象が大きすぎるため、内容を切り詰めずコピーを中止しました。話単位または短い選択範囲でお試しください。"
        case .promptEncodingFailed:
            "プロンプトを安全な文字列へ変換できませんでした。本文はコピーしていません。"
        case .clipboardWriteFailed:
            "システムクリップボードへ書き込めませんでした。もう一度お試しください。"
        }
    }
}
