public enum WorkspaceSaveState: Equatable, Sendable {
    case unsaved
    case saving
    case saved
    case failed

    /// iOS compatibility spelling for edits not yet saved locally.
    public static var dirty: Self {
        .unsaved
    }

    public var label: String {
        switch self {
        case .unsaved: "未保存"
        case .saving: "保存中"
        case .saved: "この端末に保存済み"
        case .failed: "実エラー"
        }
    }

    public var systemImage: String {
        switch self {
        case .unsaved: "circle.fill"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

public enum WorkspaceAuthUIState: Equatable, Sendable {
    case unavailable
    case signedOut
    case signingIn
    case signedIn(accountID: String)
    case failed(String)

    public var label: String {
        switch self {
        case .unavailable: "アカウント同期は未設定"
        case .signedOut: "未サインイン"
        case .signingIn: "サインイン中…"
        case let .signedIn(accountID): "サインイン済み（\(accountID)）"
        case let .failed(message): message
        }
    }
}
