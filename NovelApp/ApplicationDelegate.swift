import AppKit

/// Cmd+Q などのアプリ終了要求を受け、未保存分を保存してから終了する。
///
/// SwiftUI App 本体は `DocumentGroup` を使わない方針(D-010)のため、
/// `NSApplicationDelegate` の終了フックだけを薄く利用する。
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    private var pendingOpenURL: URL?
    private var didFinishBootstrap = false

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// cold launchのOpen Withイベントをbootstrapへ渡し、recent URLより優先する。
    func takeStartupOpenURL() -> URL? {
        defer { pendingOpenURL = nil }
        return pendingOpenURL
    }

    /// bootstrap中に遅れて届いたOpen Withイベントがあれば、確立済み状態から開く。
    func finishBootstrap() {
        didFinishBootstrap = true
        guard let pendingOpenURL else { return }
        self.pendingOpenURL = nil
        openDocumentFromFinder(pendingOpenURL)
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "novelpkg" }) else {
            return
        }

        if didFinishBootstrap, appState != nil {
            openDocumentFromFinder(url)
        } else {
            // 単一ウィンドウ方針のため、cold launch時は最後に届いた1作品だけを採用する。
            pendingOpenURL = url
        }
    }

    private func openDocumentFromFinder(_ url: URL) {
        guard let appState else {
            pendingOpenURL = url
            return
        }
        Task { @MainActor in
            _ = await appState.openExternalDocument(at: url)
        }
    }

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
