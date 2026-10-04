import Foundation

public enum ManuscriptCopyFailure: Error, Sendable, Equatable {
    case staleContext
    case compositionInProgress
    case emptyContent
    case contentTooLarge
    case copyPreparationFailed
    case clipboardWriteFailed
}

public enum ManuscriptCopyOutcome: Sendable, Equatable {
    case success
    case failure(ManuscriptCopyFailure)
}

/// コピー文字列本文を持たない、コピー結果の一時通知。
public struct ManuscriptCopyNotice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let outcome: ManuscriptCopyOutcome

    private let concise: Bool

    public var failure: ManuscriptCopyFailure? {
        if case let .failure(failure) = outcome {
            return failure
        }
        return nil
    }

    public static var success: Self {
        Self(outcome: .success)
    }

    public init(failure: ManuscriptCopyFailure?) {
        id = UUID()
        outcome = failure.map { .failure($0) } ?? .success
        concise = true
    }

    public init(id: UUID = UUID(), outcome: ManuscriptCopyOutcome) {
        self.id = id
        self.outcome = outcome
        concise = false
    }

    public var title: String {
        switch outcome {
        case .success:
            "コピーしました"
        case .failure:
            "コピーできませんでした"
        }
    }

    public var message: String {
        switch outcome {
        case .success:
            "クリップボードへコピーしました。"
        case let .failure(failure):
            concise ? failure.conciseMessage : failure.message
        }
    }
}

private extension ManuscriptCopyFailure {
    var conciseMessage: String {
        switch self {
        case .contentTooLarge: "対象が大きすぎるため、内容を切り詰めずコピーを中止しました。"
        case .copyPreparationFailed: "コピーする文字列を準備できませんでした。"
        case .clipboardWriteFailed: "システムクリップボードへ書き込めませんでした。"
        default: message
        }
    }

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
        case .copyPreparationFailed:
            "コピーする文字列を準備できませんでした。本文はコピーしていません。"
        case .clipboardWriteFailed:
            "システムクリップボードへ書き込めませんでした。もう一度お試しください。"
        }
    }
}
