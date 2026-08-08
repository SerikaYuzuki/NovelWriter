import EditorKit
import NovelAI

extension AIProofreadingPhase {
    var presentationTitle: String {
        switch self {
        case .idle:
            "待機中"
        case .preview:
            "送信前の確認"
        case .running:
            "校正中"
        case .cancelling:
            "キャンセル中"
        case .result:
            "結果"
        case .applied:
            "適用済み"
        case .failed:
            "失敗"
        case .cancelled:
            "キャンセル済み"
        case .invalidated:
            "再確認が必要"
        }
    }
}

extension AIProofreadingStaleReason {
    var presentationMessage: String {
        switch self {
        case .appUnavailable:
            "作品を編集できる状態ではなくなりました。"
        case .documentChanged:
            "別の作品または別の作品世代へ切り替わりました。"
        case .episodeChanged:
            "対象の章または話が切り替わりました。"
        case .providerChanged:
            "送信先または送信条件が変わりました。"
        case .sourceChanged:
            "確認した選択本文と送信対象が一致しません。"
        case let .editorChanged(error):
            error.presentationMessage
        }
    }
}

extension AIProofreadingFailure {
    var presentationMessage: String {
        switch self {
        case let .editor(error):
            error.presentationMessage
        case let .request(error):
            error.presentationMessage
        case let .stale(reason):
            reason.presentationMessage
        }
    }
}

private extension EditorAISelectionUnavailableReason {
    var presentationMessage: String {
        switch self {
        case .inactiveSurface:
            "本文エディタが表示されていません。"
        case .editorInactive:
            "本文エディタを選択してからやり直してください。"
        case .imeComposing:
            "日本語入力の変換を確定してからやり直してください。"
        case .emptySelection:
            "校正する本文を選択してください。"
        case .invalidSelection:
            "現在の選択範囲を取得できません。選択し直してください。"
        }
    }
}

private extension EditorAISelectionStaleReason {
    var presentationMessage: String {
        switch self {
        case .sessionChanged:
            "選択を取得した編集セッションが終了しました。"
        case .inactiveSurface:
            "対象の本文エディタが閉じられました。"
        case .surfaceChanged:
            "対象の本文エディタが再生成されました。"
        case .editorInactive:
            "対象の本文エディタがアクティブではありません。"
        case .imeComposing:
            "対象範囲で日本語入力の変換が始まりました。"
        case .contentChanged:
            "校正中に本文が変更されました。"
        case .selectionChanged:
            "校正中に選択範囲が変更されました。"
        case .rangeChanged:
            "校正中に対象範囲の位置が変更されました。"
        case .invalidRange:
            "校正対象の範囲が現在の本文に存在しません。"
        case .sourceChanged:
            "校正対象の原文が変更されました。"
        }
    }
}

private extension EditorAISelectionError {
    var presentationMessage: String {
        switch self {
        case let .unavailable(reason):
            reason.presentationMessage
        case let .stale(reason):
            reason.presentationMessage
        case .alreadyApplied:
            "この校正案はすでに適用済みです。"
        case .replacementRejected:
            "本文エディタが置換を受け付けませんでした。原文は変更されていません。"
        }
    }
}

private extension AIError {
    var presentationMessage: String {
        switch self {
        case .emptySelection:
            "校正する本文を選択してください。"
        case .invalidBudget:
            "このリクエストの上限設定が無効です。"
        case .budgetExceedsAbsoluteLimit:
            "このリクエストの上限設定がアプリの安全上限を超えています。"
        case .invalidProviderDescriptor:
            "送信先の能力または設定を確認できません。"
        case .inputCharacterLimitExceeded, .inputUTF8ByteLimitExceeded:
            "選択本文と送信契約が入力上限を超えています。範囲を短くしてください。"
        case .outputCharacterLimitExceeded, .outputUTF8ByteLimitExceeded,
             .outputTokenLimitExceeded, .outputWarningCountLimitExceeded:
            "受信内容が安全上限を超えたため、結果として受け付けませんでした。"
        case .applicationPromptEncodingFailed:
            "送信内容を安全に構成できませんでした。"
        case .providerMismatch:
            "確認した送信先と実行する送信先が一致しません。"
        case .confirmationAlreadyUsed:
            "この送信確認はすでに使用されています。選択からやり直してください。"
        case .authenticationRequired:
            "送信先の認証が必要です。"
        case .offline:
            "ネットワークに接続できません。"
        case .timedOut:
            "制限時間内に校正が完了しませんでした。"
        case .rateLimited:
            "送信先の利用頻度上限に達しました。"
        case .quotaExceeded:
            "送信先の利用量上限に達しました。"
        case .providerUnavailable:
            "送信先を現在利用できません。"
        case .refused:
            "送信先がこのリクエストを受け付けませんでした。"
        case .invalidResponse:
            "応答が校正結果の厳密な形式に一致しません。原文は変更されていません。"
        case .cancelled:
            "校正をキャンセルしました。"
        }
    }
}

extension AIProviderDataUseStatus {
    var presentationText: String {
        switch self {
        case .providerReportedNotUsed:
            "Provider申告: 利用しない"
        case .providerReportedUsed:
            "Provider申告: 利用する"
        case .notVerified:
            "未確認"
        }
    }
}
