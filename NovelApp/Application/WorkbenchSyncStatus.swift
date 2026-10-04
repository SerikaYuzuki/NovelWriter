import NovelSyncV2Application
import NovelUI

struct WorkbenchSyncStatus: Equatable {
    let title: String
    let systemImage: String
    var isWarning = false
    var tone: StatusTone = .secondary
    var isSyncing = false

    static func resolve(
        saveState: DocumentSaveState,
        progress: SyncV2RemoteProgress?,
        accountState: SyncV2LibraryAccountState?,
        isSignedIn: Bool,
        isRequesting: Bool
    ) -> Self {
        if saveState == .failed {
            return Self(title: "保存に失敗", systemImage: "xmark.circle.fill", isWarning: true, tone: .danger)
        }
        if isRequesting || saveState == .saving {
            return Self(title: "保存・同期中", systemImage: "arrow.triangle.2.circlepath", tone: .active, isSyncing: isRequesting || isRemoteSyncing(progress))
        }
        if saveState == .unsaved {
            return Self(title: "未保存", systemImage: "circle.dotted")
        }
        if accountState == .unbound {
            return Self(title: "端末に保存", systemImage: "internaldrive")
        }
        if !isSignedIn {
            return Self(title: "要サインイン", systemImage: "person.crop.circle.badge.exclamationmark", isWarning: true, tone: .warning)
        }
        guard accountState == .active else {
            return Self(title: "同期を確認", systemImage: "lock.shield", isWarning: accountState != nil)
        }
        guard let progress else { return Self(title: "同期を確認", systemImage: "arrow.triangle.2.circlepath") }
        switch progress {
        case .idle: return Self(title: "同期を確認", systemImage: "arrow.triangle.2.circlepath")
        case .noChanges: return Self(title: "同期済み", systemImage: "checkmark.circle.fill", tone: .success)
        case .pending: return Self(title: "同期待ち", systemImage: "clock.fill")
        case .syncing: return Self(title: "同期中", systemImage: "arrow.triangle.2.circlepath", tone: .active, isSyncing: true)
        case .offline: return Self(title: "通信待ち", systemImage: "wifi.slash", tone: .offline)
        case .retryable: return Self(title: "再試行待ち", systemImage: "arrow.clockwise.circle.fill", isWarning: true, tone: .warning)
        case .needsChoice: return Self(title: "競合あり", systemImage: "exclamationmark.triangle.fill", isWarning: true, tone: .warning)
        case .readyForSafeAdoption: return Self(title: "サーバーに新しい版があります", systemImage: "arrow.down.circle.fill", tone: .active)
        case .authenticationRequired: return Self(title: "要サインイン", systemImage: "person.crop.circle.badge.exclamationmark", isWarning: true, tone: .warning)
        case .fenceChanged, .parkedDifferentAccount, .quarantined:
            return Self(title: "同期を確認", systemImage: "lock.shield.fill", isWarning: true, tone: .warning)
        case .failed(.remoteDataUnavailable): return Self(title: "同期先を確認", systemImage: "xmark.circle.fill", isWarning: true, tone: .danger)
        case .failed(.uploadTooLarge): return Self(title: "送信上限を超過", systemImage: "exclamationmark.octagon.fill", isWarning: true, tone: .danger)
        case .failed, .receiptMismatch: return Self(title: "同期失敗", systemImage: "xmark.circle.fill", isWarning: true, tone: .danger)
        }
    }

    private static func isRemoteSyncing(_ progress: SyncV2RemoteProgress?) -> Bool {
        if case .syncing = progress {
            true
        } else {
            false
        }
    }
}
