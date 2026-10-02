import Foundation
import NovelSyncV2Application
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    /// Edge errors are transport failures, not v2 envelopes. Do not inspect
    /// their body or require origin-only headers before classifying them.
    nonisolated static func validateTransportStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SyncV2Failure.retryable(.lostResponse)
        }
        switch http.statusCode {
        case 408, 429, 500 ... 599: throw SyncV2Failure.retryable(.serverUnavailable)
        case 401: throw SyncV2Failure.authenticationRequired
        case 403: throw SyncV2Failure.accountFenceChanged
        default: break
        }
    }

    func validateSyncResponseHeaders(_ response: URLResponse) throws {
        try Self.validateTransportStatus(response)
        guard let http = response as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              httpContentType(response) == mediaType else {
            throw SyncV2Failure.receiptMismatch
        }
    }
}
