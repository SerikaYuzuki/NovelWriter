import NovelAuth

func appleSignInFailureMessage(_ error: any Error) -> String {
    guard let authError = error as? AuthError else {
        return "サインインを完了できませんでした。もう一度お試しください。"
    }
    switch authError {
    case let .remote(remote):
        switch remote.code {
        case "temporarilyUnavailable", "rateLimited":
            return "サーバーに接続できません。接続を確認して再試行してください。"
        case "providerExchangeIndeterminate":
            return "ログインの結果を確認できませんでした。時間をおいて再試行してください。"
        case "providerIdentityInvalid", "providerAudienceMismatch", "providerIssuerMismatch", "nonceMismatch", "stateMismatch":
            return "ログインを確認できませんでした。もう一度お試しください。"
        default:
            return "サインインを完了できませんでした。もう一度お試しください。"
        }
    case .invalidProductionOrigin, .invalidMediaType, .missingNoStore, .invalidWireResponse,
         .invalidCanonicalResponse, .invalidResponseSemantics:
        return "サーバー設定を確認できませんでした。時間をおいて再試行してください。"
    case .operationJournalConflict:
        return "前回のログイン処理が残っています。時間をおいて再試行してください。"
    case .restartAuthentication:
        return "サインインをもう一度お試しください。"
    default:
        return "サインインを完了できませんでした。もう一度お試しください。"
    }
}
