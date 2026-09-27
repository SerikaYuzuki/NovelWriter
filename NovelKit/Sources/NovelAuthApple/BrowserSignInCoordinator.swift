import AuthenticationServices
import Foundation
import NovelAuth
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system browser owns provider credentials; only a constant completion URL returns.
@MainActor
public final class BrowserSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<Void, Error>?

    override public init() {
        super.init()
    }

    public func authorize(url: URL) async throws {
        guard session == nil else { throw AuthError.authorizationInProgress }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let completion = Self.makeCompletionHandler { [weak self] url, error in
                    guard let self else { return }
                    if let error {
                        finish(.failure(error))
                    } else if url?.scheme == "fuminiwa-auth", url?.host == "complete" {
                        finish(.success(()))
                    } else {
                        finish(.failure(AuthError.providerRejected))
                    }
                }
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "fuminiwa-auth", completionHandler: completion)
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() {
                    self.finish(.failure(AuthError.providerRejected))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.session?.cancel()
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    /// AuthenticationServices can call back on SafariLaunchAgent's XPC queue.
    /// The entry closure must be nonisolated, before it hops to the main actor.
    nonisolated static func makeCompletionHandler(
        deliver: @escaping @MainActor @Sendable (URL?, Error?) -> Void
    ) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            Task { @MainActor in
                deliver(url, error)
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }

    public func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
        #endif
    }
}
