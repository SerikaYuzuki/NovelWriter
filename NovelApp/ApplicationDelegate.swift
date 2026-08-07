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
    private var terminationReplyTask: Task<Void, Never>?

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
        beginTerminationRequest { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    /// AppKitへ返すreplyを一つに集約する。internalなのは、重複要求でreplyが
    /// 二重送信されないことをNSApplicationへ副作用を出さずテストするため。
    func beginTerminationRequest(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard terminationReplyTask == nil else { return .terminateLater }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let appState else {
                reply(true)
                return
            }

            let shouldTerminate = await appState.saveBeforeTermination()
            if !shouldTerminate {
                // 取消後の次の終了要求は、新しいsingle-flightとして再試行できる。
                terminationReplyTask = nil
            }
            reply(shouldTerminate)
        }
        terminationReplyTask = task

        return .terminateLater
    }
}
