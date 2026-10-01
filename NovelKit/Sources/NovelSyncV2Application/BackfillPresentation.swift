import Foundation

/// Shared semantic mapping for history, shelf and restore on both platforms.
public enum SyncV2HistoryFetchState: String, Sendable, Equatable, CaseIterable {
    case complete, running, paused, offline, constrained, interrupted, validationFailed, suspended

    public var label: String {
        switch self {
        case .complete: "履歴を取得しました"
        case .running: "古い履歴を取得中…"
        case .paused, .offline, .constrained: "オンラインで取得"
        case .interrupted: "古い履歴を取得できませんでした・通信が途切れました"
        case .validationFailed: "サーバーの履歴を確認できませんでした"
        case .suspended: "アカウントの状態を確認してください"
        }
    }

    public var actionLabel: String? {
        switch self {
        case .complete, .running, .suspended: nil
        case .validationFailed, .interrupted: "再試行"
        case .paused, .offline, .constrained: "オンラインで取得"
        }
    }

    public var details: String? {
        self == .validationFailed
            ? "取得した履歴の整合性を確認できないため停止しました。端末の原稿と未送信の変更は保持しています。自動では再試行しません。"
            : nil
    }

    public static let restoreNotice = "この版はまだ端末にありません。取得後に復元できます。"
    public static let conflictWaiting = "サーバーの変更を確認するため古い履歴を取得しています。原稿は端末に保存済みです。"
    public static let constrainedConfirmation = "省データモード、または通信料金がかかる可能性のある接続です。古い履歴を取得しますか？"
}

public enum SyncV2HistoryFetchRequest: Sendable, Equatable {
    case queued, needsNetworkConfirmation, offline, unavailable
}
