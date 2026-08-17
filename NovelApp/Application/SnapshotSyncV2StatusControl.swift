import NovelSyncV2Application
import SwiftUI

/// macOS presentation of the shared v2 projection.  It intentionally accepts
/// only value state from `SyncV2Application`; no transport, SQL, or package
/// detail is allowed to leak into the toolbar.
struct SnapshotSyncV2StatusControl: View {
    let state: SyncUIState?
    let saveState: DocumentSaveState
    let reviewConflict: () -> Void
    let adoptServerVersion: () -> Void
    let canCloneIntoAccount: Bool
    let cloneIntoAccount: () -> Void

    @State private var showsDetails = false

    private var label: String {
        if canCloneIntoAccount {
            return "この作品をアカウントへ追加"
        }
        guard let state else {
            return saveState == .saved ? "同期状態を確認中" : "この端末に保存中"
        }
        if saveState != .saved {
            return "この端末に保存中"
        }
        return state.japaneseLabel
    }

    private var detail: String {
        if canCloneIntoAccount {
            return "この端末だけの作品を、サインイン中のアカウントへ別の作品として追加できます。元の作品はこの端末に残ります。"
        }
        guard let state else {
            return "この端末への保存が完了すると、同期状態を表示します。"
        }
        if saveState != .saved {
            return "変更内容をこの端末へ保存しています。入力はそのまま続けられます。"
        }
        switch state.remoteProgress {
        case .idle, .noChanges:
            return "この端末の保存内容は同期済みです。"
        case .pending:
            return "この端末に保存済みです。同期をバックグラウンドで再開します。"
        case .offline:
            return "この端末に保存済みです。オフラインのため、接続時に再開します。"
        case .needsChoice:
            return "この端末の版とサーバーの版を保持しています。残す方法を選んでください。"
        case .readyForSafeAdoption:
            return "サーバーの版を安全な編集境界で適用できます。"
        case .authenticationRequired:
            return "サインインすると同期を再開できます。編集内容はこの端末に保存されています。"
        case .parkedDifferentAccount:
            return "別のアカウントのため保留中です。作品はこの端末に残っています。"
        case .fenceChanged, .quarantined:
            return "安全確認が完了するまで同期を保留しています。"
        case .retryable:
            return "同期を再試行できます。編集内容はこの端末に残っています。"
        case .syncing:
            return "同期中です。執筆はそのまま続けられます。"
        case .failed, .receiptMismatch:
            return "同期で実エラーが発生しました。編集内容はこの端末に残っています。"
        }
    }

    private var systemImage: String {
        guard let state else { return "arrow.triangle.2.circlepath" }
        return switch state.remoteProgress {
        case .idle, .noChanges: "checkmark.circle"
        case .pending, .syncing: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .needsChoice: "exclamationmark.triangle"
        case .readyForSafeAdoption: "arrow.down.circle"
        case .authenticationRequired, .parkedDifferentAccount, .fenceChanged, .quarantined:
            "lock.shield"
        case .retryable, .failed, .receiptMismatch: "exclamationmark.circle"
        }
    }

    private var canReviewConflict: Bool {
        guard let state else { return false }
        return state.remoteProgress == .needsChoice && state.conflict != nil
    }

    private var canAdoptServerVersion: Bool {
        guard let state else { return false }
        if case .readyForSafeAdoption = state.remoteProgress {
            return true
        }
        return false
    }

    var body: some View {
        Button {
            if canReviewConflict {
                reviewConflict()
            } else if canAdoptServerVersion {
                adoptServerVersion()
            } else {
                showsDetails.toggle()
            }
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canReviewConflict ? .orange : .secondary)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(canReviewConflict ? "競合の選択肢を表示します" : detail)
        .accessibilityIdentifier("snapshotSyncV2.status")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label(label, systemImage: systemImage)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canReviewConflict {
                    Button("競合を確認") {
                        showsDetails = false
                        reviewConflict()
                    }
                    .buttonStyle(.borderedProminent)
                } else if canAdoptServerVersion {
                    Button("サーバーの版を適用") {
                        showsDetails = false
                        adoptServerVersion()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if canCloneIntoAccount {
                    Button("この作品をこのアカウントへ追加して同期") {
                        showsDetails = false
                        cloneIntoAccount()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}
