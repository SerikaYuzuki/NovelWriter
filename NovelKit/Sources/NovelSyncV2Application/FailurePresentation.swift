import Foundation
#if canImport(os)
import os
#endif

public func remoteOnlyOpenErrorMessage(_ error: any Error) -> String {
    switch syncV2FailureKind(error) {
    case .offline:
        "インターネットに接続できません。接続を確認して、もう一度作品を開いてください。"
    case .authenticationRequired:
        "サインインの確認が必要なため、作品を取得できませんでした。アカウントの状態を確認してください。"
    case .accountFenceChanged, .quarantined(.differentAccount), .quarantined(.changedFence):
        "アカウントの状態が変わったため、取り込みを中止しました。アカウントを確認して再試行してください。"
    case .retryable(.rateLimited):
        "サーバーが混み合っています。少し待ってから、もう一度作品を開いてください。"
    case .retryable:
        "作品の取得中に通信が途切れました。もう一度作品を開いてください。"
    case .quarantined(.invalidRemoteData), .receiptMismatch:
        "取得した作品データを検証できないため、取り込みを中止しました。"
    case .fatal(.remoteDataUnavailable), .fatal(.remoteWorkDeleted):
        "サーバー上の作品データを取得できませんでした。作品一覧を更新して再試行してください。"
    default:
        "作品を安全に取り込めませんでした。現在の端末内の作品は変更していません。"
    }
}

/// Store a bounded category, never a server payload, path, or manuscript-bearing error string.
public func syncV2FailureKind(_ error: any Error) -> SyncV2Failure {
    if let failure = error as? SyncV2Failure {
        return failure
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost: return .offline
        case .cannotConnectToHost, .cannotFindHost, .timedOut: return .retryable(.serverUnavailable)
        default: break
        }
    }
    return .fatal(.unexpected)
}

public func logSyncV2PresentationFailure(_ error: any Error) {
    #if canImport(os)
    let kind = syncV2FailureKind(error)
    Logger(subsystem: "dev.serikayuzuki.fuminiwa", category: "library")
        .error("Library operation failed: \(String(describing: kind), privacy: .public)")
    #endif
}
