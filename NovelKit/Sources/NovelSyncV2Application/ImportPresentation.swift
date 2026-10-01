import Foundation
import NovelSyncV2

public extension ImportPhase {
    var japaneseLabel: String {
        switch stage {
        case .receiving:
            let received = String(format: "%.1f", Double(receivedBytes) / 1_000_000)
            if let totalBytes {
                let total = String(format: "%g", (Double(totalBytes) / 100_000).rounded() / 10)
                return "サーバーから受信中 \(received) / \(total) MB"
            }
            return "サーバーから受信中 \(received) MB"
        case .checking: return "内容を確認中…"
        case .saving: return "この端末に保存中…"
        case .opening: return "開いています…"
        }
    }

    var accessibilityValue: String {
        if stage == .receiving, let fraction {
            return "取り込み中、\(Int(fraction * 100))パーセント"
        }
        return "取り込み中、\(japaneseLabel)"
    }
}

public extension SyncV2LibraryPresentation {
    static func importFailure(_ failure: SyncV2Failure) -> String {
        let reason = switch failure {
        case .offline, .retryable(.lostResponse): "通信が途切れました"
        case .retryable(.serverUnavailable): "サーバーに接続できません"
        case .authenticationRequired: "サインインが必要です"
        case .accountFenceChanged: "アカウントが変更されました"
        default: "内容を確認できませんでした"
        }
        return "取り込めませんでした・" + reason
    }
}
