import AppKit

/// Cmd+Q などのアプリ終了要求を受け、未保存分を保存してから終了する。
///
/// SwiftUI App 本体は `DocumentGroup` を使わない方針(D-010)のため、
/// `NSApplicationDelegate` の終了フックだけを薄く利用する。
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            guard let appState else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            let shouldTerminate = await appState.saveBeforeTermination()
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }

        return .terminateLater
    }
}
