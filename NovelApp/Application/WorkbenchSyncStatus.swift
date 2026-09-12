import NovelSyncV2Application

struct WorkbenchSyncStatus: Equatable {
    let title: String
    let systemImage: String
    var isWarning = false

    static func resolve(
        saveState: DocumentSaveState,
        progress: SyncV2RemoteProgress?,
        accountState: SyncV2LibraryAccountState?,
        isSignedIn: Bool,
        isRequesting: Bool
    ) -> Self {
        if saveState == .failed {
            return Self(title: "保存に失敗", systemImage: "exclamationmark.circle", isWarning: true)
        }
        if isRequesting || saveState == .saving {
            return Self(title: "保存・同期中", systemImage: "arrow.triangle.2.circlepath")
        }
        if saveState == .unsaved {
            return Self(title: "未保存", systemImage: "circle.dotted")
        }
        if accountState == .unbound {
            return Self(title: "端末に保存", systemImage: "internaldrive")
        }
        if !isSignedIn {
            return Self(title: "要サインイン", systemImage: "person.crop.circle.badge.exclamationmark", isWarning: true)
        }
        guard accountState == .active else {
            return Self(title: "同期を確認", systemImage: "lock.shield", isWarning: accountState != nil)
        }
        guard let progress else { return Self(title: "同期を確認", systemImage: "arrow.triangle.2.circlepath") }
        switch progress {
        case .idle: return Self(title: "同期を確認", systemImage: "arrow.triangle.2.circlepath")
        case .noChanges: return Self(title: "同期済み", systemImage: "checkmark.circle")
        case .pending: return Self(title: "同期待ち", systemImage: "clock")
        case .syncing: return Self(title: "同期中", systemImage: "arrow.triangle.2.circlepath")
        case .offline: return Self(title: "通信待ち", systemImage: "wifi.slash")
        case .retryable: return Self(title: "再試行待ち", systemImage: "arrow.clockwise", isWarning: true)
        case .needsChoice: return Self(title: "競合あり", systemImage: "exclamationmark.triangle", isWarning: true)
        case .readyForSafeAdoption: return Self(title: "受信を適用", systemImage: "arrow.down.circle")
        case .authenticationRequired: return Self(title: "要サインイン", systemImage: "person.crop.circle.badge.exclamationmark", isWarning: true)
        case .fenceChanged, .parkedDifferentAccount, .quarantined:
            return Self(title: "同期を確認", systemImage: "lock.shield", isWarning: true)
        case .failed, .receiptMismatch: return Self(title: "同期失敗", systemImage: "exclamationmark.circle", isWarning: true)
        }
    }
}
