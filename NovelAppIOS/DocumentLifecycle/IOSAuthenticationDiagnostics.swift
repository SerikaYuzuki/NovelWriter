import Foundation
import NovelAuth
import NovelAuthApple
import OSLog

private let iosAuthenticationLogger = Logger(
    subsystem: "dev.serikayuzuki.fuminiwa.ios",
    category: "authentication"
)

/// Logs only a fixed authentication milestone. The phase type intentionally
/// carries no identifiers, URLs, credentials, or response data.
func logIOSAppleAuthenticationPhase(_ phase: AppleAuthenticationPhase) {
    let line = "auth apple phase=\(phase.rawValue)"
    print("[FUMINIWA] \(line)")
    iosAuthenticationLogger.info("\(line, privacy: .public)")
}

enum IOSAppleAuthenticationBoundaryPhase: String {
    case entry
    case unavailable
    case requestUnavailable = "request-unavailable"
    case staleTransitionRecovered = "stale-transition-recovered"
    case preflightRejected = "preflight-rejected"
    case oldScopeRejected = "old-scope-rejected"
    case challengeRequestStart = "challenge-request-start"
}

func logIOSAppleAuthenticationBoundary(
    _ phase: IOSAppleAuthenticationBoundaryPhase
) {
    let line = "auth apple boundary=\(phase.rawValue)"
    print("[FUMINIWA] \(line)")
    iosAuthenticationLogger.info("\(line, privacy: .public)")
}

func logAppleAuthenticationFailure(
    phase: String,
    error: (any Error)? = nil
) {
    let token: String = if let authError = error as? AuthError {
        authError.diagnosticToken
    } else if let error, let networkToken = AuthNetworkDiagnostic.token(for: error) {
        networkToken
    } else if let error {
        String(reflecting: type(of: error))
    } else {
        "cancelled"
    }
    let line = "auth apple failed phase=\(phase) error=\(token)"
    print("[FUMINIWA] \(line)")
    iosAuthenticationLogger.error("\(line, privacy: .public)")
}
