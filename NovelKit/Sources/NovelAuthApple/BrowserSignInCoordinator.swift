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
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "fuminiwa-auth") { [weak self] url, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.finish(.failure(error))
                        } else if url?.scheme == "fuminiwa-auth", url?.host == "complete" {
                            self.finish(.success(()))
                        } else {
                            self.finish(.failure(AuthError.providerRejected))
                        }
                    }
                }
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
