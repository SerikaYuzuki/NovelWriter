import AuthenticationServices
import Foundation
@testable import NovelAuthApple
import Testing

@Suite("Browser authentication callback isolation")
struct BrowserSignInCoordinatorTests {
    @Test("Safari background completion reaches the main actor", arguments: [false, true])
    @MainActor
    func backgroundCompletion(cancelled: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let callback = BrowserSignInCoordinator.makeCompletionHandler { url, error in
                MainActor.assertIsolated()
                if cancelled {
                    #expect(url == nil)
                    #expect((error as NSError?)?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue)
                } else {
                    #expect(url == URL(string: "fuminiwa-auth://complete"))
                    #expect(error == nil)
                }
                continuation.resume()
            }
            DispatchQueue(label: "test.SafariLaunchAgent").async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                if cancelled {
                    callback(nil, ASWebAuthenticationSessionError(.canceledLogin))
                } else {
                    callback(URL(string: "fuminiwa-auth://complete"), nil)
                }
            }
        }
    }
}
