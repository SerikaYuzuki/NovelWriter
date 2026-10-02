import Foundation
import NovelSyncV2

/// Semantic presentation only; UI targets translate these tones to their design tokens.
public struct SyncV2LibraryStatus: Equatable, Sendable {
    public enum Tone: String, CaseIterable, Sendable {
        case success, active, secondary, offline, warning, danger
    }

    public let text: String
    public let symbol: String
    public let tone: Tone

    public init(text: String, symbol: String, tone: Tone) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    public func delayed(since: Date?, now: Date) -> Self {
        guard tone != .success, SyncV2DelayNotice.isDelayed(since: since, now: now) else { return self }
        let prefix = since.map { $0 > now } == true
            ? "未同期の変更があります（時刻を確認できません）"
            : "未同期の変更があります"
        return .init(text: prefix + "・" + text, symbol: symbol, tone: tone)
    }

    public static func resolve(
        availability: SyncV2LibraryAvailability,
        accountState: SyncV2LibraryAccountState,
        remoteHeadConfirmed: Bool,
        progress: SyncV2RemoteProgress
    ) -> Self {
        if accountState == .parkedDifferentAccount {
            return .init(text: "別のアカウントのため保留中", symbol: "lock", tone: .secondary)
        }
        if accountState == .quarantined {
            return .init(text: "安全確認後に同期を再開します", symbol: "lock", tone: .warning)
        }
        if availability == .remoteOnly {
            return .init(text: "未取得", symbol: "arrow.down.circle", tone: .active)
        }
        if accountState == .unbound {
            return .init(text: "この端末のみ", symbol: "internaldrive", tone: .secondary)
        }
        switch progress {
        case .idle, .noChanges:
            return remoteHeadConfirmed
                ? .init(text: "同期済み", symbol: "checkmark.circle", tone: .success)
                : .init(text: "同期待ち", symbol: "clock", tone: .secondary)
        case .pending:
            return .init(text: "同期待ち", symbol: "clock", tone: .secondary)
        case .syncing:
            return .init(text: "同期中", symbol: "arrow.triangle.2.circlepath", tone: .active)
        case .offline:
            return .init(text: "オフライン・接続時再開", symbol: "wifi.slash", tone: .offline)
        case .authenticationRequired, .parkedDifferentAccount:
            return .init(text: progress.japaneseLabel, symbol: "lock", tone: .secondary)
        case .fenceChanged, .quarantined:
            return .init(text: progress.japaneseLabel, symbol: "lock", tone: .warning)
        case .retryable:
            return .init(text: progress.japaneseLabel, symbol: "arrow.triangle.2.circlepath", tone: .secondary)
        case .needsChoice:
            return .init(text: "競合・確認が必要", symbol: "exclamationmark.triangle", tone: .warning)
        case .readyForSafeAdoption:
            return .init(text: progress.japaneseLabel, symbol: "arrow.down.circle", tone: .active)
        case .failed, .receiptMismatch:
            return .init(text: progress.japaneseLabel, symbol: "exclamationmark.circle", tone: .danger)
        }
    }

    public static func resolve(
        availability: SyncV2LibraryAvailability,
        accountState: SyncV2LibraryAccountState,
        remoteHeadConfirmed: Bool,
        state: SyncUIState?
    ) -> Self {
        resolve(availability: availability, accountState: accountState,
                remoteHeadConfirmed: remoteHeadConfirmed, progress: state?.remoteProgress ?? .idle)
    }
}

public enum SyncV2LibraryPresentation {
    public static let offlineNotice = "オフライン・未取得の作品は接続後に取り込めます"
    public static let longImportNotice = "履歴が多い作品は数分かかることがあります。ほかの作品はこのまま使えます。"
    public static let remoteOnlyHint = "この端末に取り込んでから開きます"
    public static let importBusyReason = "取り込み中です。完了するか中止すると使えます。"

    public static func precedes(title: String, workID: WorkID, otherTitle: String, otherWorkID: WorkID) -> Bool {
        let order = title.localizedStandardCompare(otherTitle)
        return order == .orderedSame ? workID.description < otherWorkID.description : order == .orderedAscending
    }

    public static func isOffline(_ failure: SyncV2Failure?) -> Bool {
        failure == .offline || failure == .retryable(.serverUnavailable) || failure == .retryable(.lostResponse)
    }
}

public extension SyncV2LibraryItem {
    var status: SyncV2LibraryStatus {
        let value = SyncV2LibraryStatus.resolve(availability: availability, accountState: accountState,
                                                remoteHeadConfirmed: remoteHeadConfirmed, progress: remoteProgress)
        return accountState == .active && availability != .remoteOnly
            ? value.delayed(since: oldestUnreceivedAt, now: Date()) : value
    }
}
